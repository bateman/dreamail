import AppKit
import GRDB
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

    /// An image host that never answers (the longest timeout there is).
    private final class DeadHost: NSObject, WKURLSchemeHandler {
        private(set) var started = 0
        private var tasks: [any WKURLSchemeTask] = []
        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            started += 1
            tasks.append(urlSchemeTask)
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
    }

    private final class Host: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var domReady = false
        var finished = false
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if HTMLBodyLayout.isDOMReadyMessage(message.body) { domReady = true }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = true
        }
    }

    /// The reading pane's case: a mail whose image host is dead. Window load
    /// never comes; the DOM-ready signal does, and the measure then gives the
    /// body its height (the pending image keeps its authored box).
    func testDeadImageHostDoesNotHoldTheMeasure() async throws {
        let dead = DeadHost()
        let host = Host()
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(dead, forURLScheme: "mmdead")
        config.userContentController.addUserScript(WKUserScript(
            source: HTMLBodyLayout.domReadyJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.add(host, name: HTMLBodyLayout.heightHandlerName)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 120),
                                configuration: config)
        webView.navigationDelegate = host
        window.contentView?.addSubview(webView)
        defer {
            config.userContentController.removeScriptMessageHandler(
                forName: HTMLBodyLayout.heightHandlerName)
            webView.removeFromSuperview()
        }
        let document = HTMLBodyDocument.assemble(
            html: "<p>Policy documents</p><img src=\"/logo.png\" width=\"600\" height=\"300\"><p>Tail</p>",
            cspMeta: "",
            styleCSS: HTMLBodyDarkMode.injectedCSS(fontScale: 1.0))
        webView.loadHTMLString(document, baseURL: URL(string: "mmdead://images.example/"))

        let deadline = Date().addingTimeInterval(10)
        while !(host.domReady && dead.started > 0), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(host.domReady, "the DOM-ready signal does not wait for images")
        XCTAssertGreaterThan(dead.started, 0, "the image is requested and never answered")
        XCTAssertFalse(host.finished, "window load waits for the dead host")

        let result: Any? = await withCheckedContinuation { done in
            webView.evaluateJavaScript(HTMLBodyLayout.installLayoutAndMeasureJS) { value, _ in
                done.resume(returning: value)
            }
        }
        let height = try XCTUnwrap(HTMLBodyLayout.measuredHeight(fromScriptResult: result))
        XCTAssertGreaterThan(height, MessageBodyHeight.placeholder,
                             "measured to its content, not left at the placeholder")
        XCTAssertFalse(host.finished)
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

    func testAMessageWithoutRemoteImagesNeverWaitsNorFetches() async {
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
