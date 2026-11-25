import AppKit
import GRDB
import Network
import WebKit
import XCTest

/// Opening a message never waits on an image host (the regression after the
/// remote-image cache: a slow or dead host held the body at its placeholder
/// height, clipped, for the network timeout):
/// - the body is measured once its DOM is parsed, not at window load, which
///   waits for every image (`HTMLBodyLayout.domReadyJS`, `HTMLDOMReadyGate`);
/// - the app's background fetch starts only after the web view's own load
///   (`RemoteImagePaneState.step`, `bodyMounted`);
/// - the cache check before the first paint reads the database only, even
///   while a fetch of the same message hangs on a dead host.
@MainActor
final class RemoteImageOpenLatencyTests: XCTestCase {

    // MARK: Measure on DOM ready

    func testDOMReadySignalIsNeverReadAsAHeight() {
        XCTAssertTrue(HTMLBodyLayout.isDOMReadyMessage(HTMLBodyLayout.domReadyMessage))
        XCTAssertFalse(HTMLBodyLayout.isDOMReadyMessage(NSNumber(value: 300)))
        XCTAssertNil(HTMLBodyLayout.measuredHeight(fromScriptResult: HTMLBodyLayout.domReadyMessage))
        XCTAssertTrue(HTMLBodyLayout.domReadyJS.contains("messageHandlers.\(HTMLBodyLayout.heightHandlerName)"))
        XCTAssertTrue(HTMLBodyLayout.domReadyJS.contains("'\(HTMLBodyLayout.domReadyMessage)'"))
        // Well under the 2 s render timeout that reveals an unmeasured body.
        XCTAssertLessThanOrEqual(HTMLBodyLayout.domReadyGrace, 0.5)
    }

    func testGateMeasuresOnceAndOnlyTheCommittedDocument() {
        var gate = HTMLDOMReadyGate()
        XCTAssertNil(gate.domReady(), "a signal before our navigation committed is the old DOM's")
        gate.didCommit()
        let generation = gate.domReady()
        XCTAssertNotNil(generation)
        XCTAssertNil(gate.domReady(), "one grace per document")
        XCTAssertTrue(gate.graceEnded(generation: generation ?? -1), "slow images: measure now")
        XCTAssertFalse(gate.graceEnded(generation: generation ?? -1), "once")

        // Fast images: window load comes first and measures as before.
        var fast = HTMLDOMReadyGate()
        fast.didCommit()
        let armed = fast.domReady()
        fast.didFinishLoad()
        XCTAssertFalse(fast.graceEnded(generation: armed ?? -1))

        // A new navigation: the previous document's grace does nothing.
        var swapped = HTMLDOMReadyGate()
        swapped.didCommit()
        let old = swapped.domReady()
        swapped.reset()
        XCTAssertFalse(swapped.graceEnded(generation: old ?? -1))
        XCTAssertNil(swapped.domReady(), "not committed yet")
    }

    func testLoadBoundEndsANeverEndingLoadOnceAndNotAFinishedOne() {
        var stuck = HTMLDOMReadyGate()
        stuck.didCommit()
        let generation = stuck.domReady() ?? -1
        XCTAssertTrue(stuck.loadBoundReached(generation: generation), "an image that never completes")
        XCTAssertFalse(stuck.loadBoundReached(generation: generation), "once")

        var finished = HTMLDOMReadyGate()
        finished.didCommit()
        let armed = finished.domReady() ?? -1
        finished.didFinishLoad()
        XCTAssertFalse(finished.loadBoundReached(generation: armed), "window load came first")

        // A failed navigation resets the gate: no timer re-enables anything.
        var failed = HTMLDOMReadyGate()
        failed.didCommit()
        let before = failed.domReady() ?? -1
        failed.reset()
        XCTAssertFalse(failed.graceEnded(generation: before))
        XCTAssertFalse(failed.loadBoundReached(generation: before))
        XCTAssertLessThan(HTMLBodyLayout.domReadyGrace, HTMLBodyLayout.loadBound)
    }

    /// R1: the fetch waits for the load of the document on screen, not of
    /// an earlier one with the same content id.
    func testTheBodyCountsAsLoadedOnlyForTheDocumentItLoads() {
        let blocked = HTMLBodyLoadKey(contentID: "m:full", allowRemoteImages: false, fontScale: 1)
        XCTAssertTrue(RemoteImageRendering.bodyLoaded(
            finished: blocked, contentID: "m:full", allowRemoteImages: false, fontScale: 1))
        XCTAssertFalse(RemoteImageRendering.bodyLoaded(
            finished: blocked, contentID: "m:full", allowRemoteImages: true, fontScale: 1),
                       "Load images: the allowed document is a new load")
        XCTAssertFalse(RemoteImageRendering.bodyLoaded(
            finished: blocked, contentID: "m:full:cid", allowRemoteImages: false, fontScale: 1),
                       "the cid: base is a new load")
        XCTAssertFalse(RemoteImageRendering.bodyLoaded(
            finished: blocked, contentID: "m:full", allowRemoteImages: false, fontScale: 1.2))
        XCTAssertFalse(RemoteImageRendering.bodyLoaded(
            finished: nil, contentID: "m:full", allowRemoteImages: false, fontScale: 1),
                       "collapsed and re-expanded: the new view's load is awaited")
    }

    // MARK: The real body coordinator

    /// An https host that accepts the connection and never answers (the TLS
    /// handshake never completes): a dead image host under the real CSP.
    private final class SilentTLSHost: @unchecked Sendable {
        private let listener: NWListener
        private var connections: [NWConnection] = []
        private(set) var accepted = 0

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async {
                    self?.accepted += 1
                    self?.connections.append(connection)
                }
                connection.start(queue: .main)
            }
        }

        func start() async throws -> UInt16 {
            listener.start(queue: .main)
            let deadline = Date().addingTimeInterval(5)
            while listener.port == nil || listener.port?.rawValue == 0, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return try XCTUnwrap(listener.port?.rawValue)
        }

        func stop() {
            for connection in connections { connection.cancel() }
            listener.cancel()
        }
    }

    /// The reading pane's own coordinator (`HTMLBodyView.Coordinator`), the
    /// pool's web view (with its document-end scripts), the real CSP and
    /// remote images allowed, and an image whose host never answers: the
    /// body gets a height above the placeholder within about 2 s; the load
    /// counts as ended only at the bound, and no height is cached before it.
    func testRealCoordinatorMeasuresAMailWhoseImageHostNeverAnswers() async throws {
        let host = SilentTLSHost()
        let port = try await host.start()
        defer { host.stop() }

        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 120))
        window.contentView?.addSubview(container)
        let contentID = "latency-\(UUID().uuidString):full"
        let key = HTMLBodyLoadKey(contentID: contentID, allowRemoteImages: true, fontScale: 1)

        var heights: [CGFloat] = []
        var finished: [HTMLBodyLoadKey] = []
        let coordinator = HTMLBodyView.Coordinator()
        coordinator.container = container
        coordinator.contentID = contentID
        coordinator.loadedKey = key
        coordinator.setHeight = { heights.append($0) }
        coordinator.onLoadFinished = { finished.append($0) }
        defer { coordinator.dismantle() }

        let webView = HTMLWebViewPool.dequeue()
        coordinator.attach(webView, in: container, alreadyPainted: false, fade: false)
        coordinator.beginRender(byteCount: 0, variant: "full", prerenderHit: false)
        let html = "<p>Documentazione polizza</p>"
            + "<img src=\"https://127.0.0.1:\(port)/logo.png\" width=\"600\" height=\"300\">"
            + "<p>Tail</p>"
        coordinator.loadDocument(html: html, allowRemoteImages: true, fontScale: 1, in: webView)

        try await wait(seconds: 2.5) { heights.contains { $0 > MessageBodyHeight.placeholder } }
        XCTAssertTrue(heights.contains { $0 > MessageBodyHeight.placeholder },
                      "measured above the placeholder without window load: \(heights)")
        XCTAssertGreaterThan(host.accepted, 0, "the web view asked the silent host")
        XCTAssertTrue(finished.isEmpty, "the load has not ended")
        XCTAssertNil(HTMLBodyHeightCacheStore.height(contentID: contentID, fontScale: 1, width: nil),
                     "no mid-load height is cached for the next open")

        try await wait(seconds: HTMLBodyLayout.loadBound + 3) { !finished.isEmpty }
        XCTAssertEqual(finished, [key], "the bound ends a load that never ends, once")
        XCTAssertNotNil(HTMLBodyHeightCacheStore.height(contentID: contentID, fontScale: 1, width: nil),
                        "cached once the load counts as ended")
    }

    /// An image host that answers only when told to (never, for a dead
    /// host: the longest timeout there is).
    private final class ImageHost: NSObject, WKURLSchemeHandler {
        private(set) var started = 0
        private var tasks: [any WKURLSchemeTask] = []
        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            started += 1
            tasks.append(urlSchemeTask)
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
            tasks.removeAll { $0 === urlSchemeTask }
        }
        /// A slow host finally answers every pending request with `data`.
        func answer(_ data: Data) {
            for task in tasks {
                task.didReceive(URLResponse(url: task.request.url!, mimeType: "image/png",
                                            expectedContentLength: data.count,
                                            textEncodingName: nil))
                task.didReceive(data)
                task.didFinish()
            }
            tasks = []
        }
        /// A host that finally refuses every pending request.
        func fail() {
            for task in tasks { task.didFailWithError(URLError(.cannotConnectToHost)) }
            tasks = []
        }
    }

    /// The reading pane's side of the web view, reduced to what the measure
    /// needs: the DOM-ready signal, window load, and the height reports.
    private final class Pane: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var domReady = false
        var finished = false
        var heights: [CGFloat] = []
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if HTMLBodyLayout.isDOMReadyMessage(message.body) {
                domReady = true
            } else if let height = HTMLBodyLayout.measuredHeight(fromScriptResult: message.body) {
                heights.append(height)
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = true
        }
    }

    @MainActor
    private struct Harness {
        let webView: WKWebView
        let pane: Pane
        let images: ImageHost
        let window: NSWindow

        func close() {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: HTMLBodyLayout.heightHandlerName)
            webView.removeFromSuperview()
        }

        /// The measure as the coordinator installs it at the end of the
        /// DOM-ready grace.
        func measure() async -> CGFloat? {
            let result: Any? = await withCheckedContinuation { done in
                webView.evaluateJavaScript(HTMLBodyLayout.installLayoutAndMeasureJS) { value, _ in
                    done.resume(returning: value)
                }
            }
            return HTMLBodyLayout.measuredHeight(fromScriptResult: result)
        }

        func className() async -> String {
            let result: Any? = await withCheckedContinuation { done in
                webView.evaluateJavaScript("document.querySelector('img').className") { value, _ in
                    done.resume(returning: value)
                }
            }
            return (result as? String) ?? ""
        }
    }

    private func load(_ html: String) -> Harness {
        let images = ImageHost()
        let pane = Pane()
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(images, forURLScheme: "mmimg")
        config.userContentController.addUserScript(WKUserScript(
            source: HTMLBodyLayout.domReadyJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.add(pane, name: HTMLBodyLayout.heightHandlerName)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 120),
                                configuration: config)
        webView.navigationDelegate = pane
        window.contentView?.addSubview(webView)
        let document = HTMLBodyDocument.assemble(
            html: html, cspMeta: "", styleCSS: HTMLBodyDarkMode.injectedCSS(fontScale: 1.0))
        webView.loadHTMLString(document, baseURL: URL(string: "mmimg://images.example/"))
        return Harness(webView: webView, pane: pane, images: images, window: window)
    }

    private func wait(seconds: TimeInterval = 10, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A mail whose image host is dead. Window load never comes; the
    /// DOM-ready signal does, and the measure then gives the body its height
    /// (the pending image keeps its authored box).
    func testDeadImageHostDoesNotHoldTheMeasure() async throws {
        let h = load("<p>Policy documents</p><img src=\"/logo.png\" width=\"600\" height=\"300\"><p>Tail</p>")
        defer { h.close() }
        try await wait { h.pane.domReady && h.images.started > 0 }
        XCTAssertTrue(h.pane.domReady, "the DOM-ready signal does not wait for images")
        XCTAssertGreaterThan(h.images.started, 0, "the image is requested and never answered")
        XCTAssertFalse(h.pane.finished, "window load waits for the dead host")
        let measured = await h.measure()
        let height = try XCTUnwrap(measured)
        XCTAssertGreaterThan(height, MessageBodyHeight.placeholder,
                             "measured to its content, not left at the placeholder")
        XCTAssertFalse(h.pane.finished)
    }

    /// R3: an image still loading keeps its box but is not painted as
    /// failed; once its load fails it is.
    func testPendingImagesAreNotPaintedAsFailed() async throws {
        let h = load("<p>Receipt</p><img src=\"/card.png\" width=\"300\" height=\"200\">")
        defer { h.close() }
        try await wait { h.pane.domReady && h.images.started > 0 }
        _ = await h.measure()
        let pending = await h.className()
        XCTAssertTrue(pending.contains(HTMLBodyLayout.layoutImageClass), pending)
        XCTAssertFalse(pending.contains(HTMLBodyLayout.failedImageClass), pending)
        h.images.fail()
        var after = ""
        let deadline = Date().addingTimeInterval(10)
        while !after.contains(HTMLBodyLayout.failedImageClass), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            after = await h.className()
        }
        XCTAssertTrue(after.contains(HTMLBodyLayout.failedImageClass), after)
    }

    /// A slow host: measured before the image, then re-measured when it
    /// arrives (load listener), so the body never keeps a stale height.
    func testSlowImageHostReMeasuresWhenTheImageArrives() async throws {
        let h = load("<p>Thank you for your purchase!</p><img src=\"/card.png\"><p>Total</p>")
        defer { h.close() }
        try await wait { h.pane.domReady && h.images.started > 0 }
        XCTAssertFalse(h.pane.finished)
        let first = await h.measure()
        let before = try XCTUnwrap(first)
        h.images.answer(RemoteImageFetchTests.image(width: 600, height: 900))
        try await wait { (h.pane.heights.last ?? 0) > before + 600 }
        XCTAssertGreaterThan(h.pane.heights.last ?? 0, before + 600,
                             "the late image grows the body: \(before) → \(h.pane.heights)")
        try await wait { h.pane.finished }
        XCTAssertTrue(h.pane.finished)
    }

    /// A mail without images: DOM ready and window load both come, and the
    /// measure is the same at either.
    func testMailWithoutImagesMeasuresAtOnce() async throws {
        let h = load("<p>Plain HTML mail</p><p>Second paragraph</p>")
        defer { h.close() }
        try await wait { h.pane.domReady && h.pane.finished }
        XCTAssertTrue(h.pane.domReady)
        XCTAssertTrue(h.pane.finished)
        XCTAssertEqual(h.images.started, 0)
        let measured = await h.measure()
        let height = try XCTUnwrap(measured)
        XCTAssertGreaterThanOrEqual(height, CGFloat(HTMLBodyLayout.minContentHeight))
    }

    // MARK: Background fetch after the web view's load

    private func step(_ pane: inout RemoteImagePaneState, mounted: Bool,
                      count: Int = 2) -> RemoteImagePaneState.Step {
        pane.step(id: "m", allowRemoteImages: true, bodyMounted: mounted, candidateCount: count,
                  cidResolveInFlight: false, cidInlined: false, remoteBody: nil)
    }

    func testTheFetchWaitsForTheBodysOwnLoad() {
        var pane = RemoteImagePaneState()
        XCTAssertEqual(step(&pane, mounted: false), .checkCache(baseIsCIDInlined: false))
        XCTAssertTrue(pane.checkFinished("m", complete: false))
        // The live body is on screen, its images still loading.
        XCTAssertEqual(step(&pane, mounted: false), .nothing, "no request alongside the web view's")
        // Its load ended (or failed): now the background fetch.
        XCTAssertEqual(step(&pane, mounted: true), .fetchForNextOpen(baseIsCIDInlined: false))
    }

    /// Guard (held before this change too): mail with no remote image.
    func testGuardAMessageWithoutRemoteImagesNeverWaitsNorFetches() async {
        XCTAssertFalse(RemoteImagePaneState.awaitsCacheCheck(
            check: nil, allowRemoteImages: true, candidateCount: 0, hasRemoteBody: false))
        var pane = RemoteImagePaneState()
        XCTAssertEqual(step(&pane, mounted: false, count: 0), .nothing)
        XCTAssertEqual(step(&pane, mounted: true, count: 0), .nothing)
        XCTAssertNil(pane.checks["m"])

        let calls = Counter()
        let transport = RemoteImageTransport(fetch: { request, _ in
            calls.increment()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404,
                                            httpVersion: nil, headerFields: [:])!)
        }, resolve: { _ in [[93, 184, 216, 34]] })
        let html = "<p>Plain</p><img src=\"cid:logo\"><a href=\"https://example.com\">link</a>"
        let next = await RemoteImageResolver.fetchForNextOpen(
            messageId: "m", accountId: "a", baseHTML: html, preInlineBytes: 0,
            baseIsCIDInlined: false, fontScale: 1, store: nil, transport: transport)
        XCTAssertNil(next)
        XCTAssertEqual(calls.value, 0)
    }

    // MARK: The cache check never waits on a fetch

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    /// A dead host with a long timeout: the fetch for the next open hangs,
    /// while the next open's cache check answers at once (incomplete: paint
    /// live, as before). Cancelling the fetch remembers nothing, so the
    /// image is retried at the next open.
    func testDeadHostFetchNeverDelaysTheCacheCheck() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mishmail-latency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("mail.sqlite").path)
        try AppDatabase.migrator.migrate(pool)
        let store = RemoteImageStore(db: pool, flushDelayNanoseconds: 1_000_000)

        let started = Counter()
        let transport = RemoteImageTransport(fetch: { _, _ in
            started.increment()
            try await Task.sleep(nanoseconds: 120_000_000_000)
            throw URLError(.timedOut)
        }, resolve: { _ in [[93, 184, 216, 34]] })
        let html = "<p>Receipt</p><img src=\"https://dead.example/a.png\"><img src=\"https://dead.example/b.png\">"
        let fetch = Task {
            await RemoteImageResolver.fetchForNextOpen(
                messageId: "m", accountId: "a", baseHTML: html, preInlineBytes: html.utf8.count,
                baseIsCIDInlined: false, fontScale: 1, store: store, transport: transport)
        }
        let waitUntil = Date().addingTimeInterval(5)
        while started.value == 0, Date() < waitUntil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(started.value, 0, "the fetch is hanging on the dead host")

        let clock = ContinuousClock()
        let begin = clock.now
        let cached = await RemoteImageResolver.cachedBody(
            messageId: "m", accountId: "a", baseHTML: html, preInlineBytes: html.utf8.count,
            baseIsCIDInlined: false, fontScale: 1, store: store)
        let elapsed = clock.now - begin
        XCTAssertNil(cached, "incomplete: the open paints live, as before the cache")
        XCTAssertLessThan(elapsed, .seconds(1), "the check never waits on the fetch")

        fetch.cancel()
        let result = await fetch.value
        XCTAssertNil(result)
        await store.flush()
        let refused = await store.refusedKeys(messageId: "m", accountId: "a")
        let stored = await store.storedKeys(messageId: "m", accountId: "a")
        XCTAssertTrue(refused.isEmpty && stored.isEmpty, "a network failure is retried next open")
        await store.shutDown()
        try pool.close()
    }
}
