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
        let host = try SilentTLSHost()
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
        /// Paths answered at once (status, MIME type, body); others wait.
        var immediate: [String: (status: Int, mime: String, body: Data)] = [:]
        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            started += 1
            if let url = urlSchemeTask.request.url, let answer = immediate[url.path] {
                urlSchemeTask.didReceive(HTTPURLResponse(
                    url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": answer.mime])!)
                urlSchemeTask.didReceive(answer.body)
                urlSchemeTask.didFinish()
                return
            }
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

        /// Per image: failed class, computed `visibility` and `display`, and
        /// the width of its box.
        func imageStates() async throws -> (allowed: Bool, images: [String: [String: Any]]) {
            let script = """
            (function(){
              var out = {};
              var imgs = document.querySelectorAll('img');
              for (var i = 0; i < imgs.length; i++) {
                var img = imgs[i], cs = getComputedStyle(img);
                var alt = img.previousElementSibling;
                var hasAlt = !!alt && alt.classList.contains('\(HTMLBodyLayout.altTextClass)');
                out[img.id] = {
                  failed: img.classList.contains('\(HTMLBodyLayout.failedImageClass)'),
                  visibility: cs.visibility,
                  display: cs.display,
                  width: Math.round(img.getBoundingClientRect().width),
                  altText: hasAlt ? alt.textContent : '',
                  altElements: hasAlt ? alt.children.length : 0,
                  altHeight: hasAlt ? Math.round(alt.getBoundingClientRect().height) : 0,
                  altInLink: hasAlt && !!alt.closest('a'),
                  altClass: hasAlt ? alt.className : '',
                  altColor: hasAlt ? getComputedStyle(alt).color : '',
                  altBackground: hasAlt ? getComputedStyle(alt).backgroundColor : '',
                  complete: img.complete
                };
              }
              return JSON.stringify({
                allowed: document.documentElement.classList.contains('\(HTMLBodyLayout.imagesAllowedClass)'),
                images: out
              });
            })()
            """
            let result: Any? = await withCheckedContinuation { done in
                webView.evaluateJavaScript(script) { value, _ in done.resume(returning: value) }
            }
            let json = try XCTUnwrap((result as? String)?.data(using: .utf8))
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
            return (object["allowed"] as? Bool ?? false,
                    object["images"] as? [String: [String: Any]] ?? [:])
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

    private func load(_ html: String, cspMeta: String = "",
                      immediate: [String: (status: Int, mime: String, body: Data)] = [:],
                      dark: Bool = false, height: CGFloat = 120) -> Harness {
        let images = ImageHost()
        images.immediate = immediate
        let pane = Pane()
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(images, forURLScheme: "mmimg")
        config.userContentController.addUserScript(WKUserScript(
            source: HTMLBodyLayout.imageEventsJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if dark {
            config.userContentController.addUserScript(WKUserScript(
                source: HTMLBodyDarkMode.applyContrastJS, injectionTime: .atDocumentEnd,
                forMainFrameOnly: true))
        }
        config.userContentController.addUserScript(WKUserScript(
            source: HTMLBodyLayout.domReadyJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.add(pane, name: HTMLBodyLayout.heightHandlerName)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: height),
                                configuration: config)
        webView.navigationDelegate = pane
        if dark { webView.appearance = NSAppearance(named: .darkAqua) }
        window.contentView?.addSubview(webView)
        let document = HTMLBodyDocument.assemble(
            html: html, cspMeta: cspMeta, styleCSS: HTMLBodyDarkMode.injectedCSS(fontScale: 1.0))
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
        let h = load("<p>Receipt</p><img id=\"card\" src=\"/card.png\" alt=\"x\" width=\"300\" height=\"200\">",
                     cspMeta: allowedCSPWithTestScheme)
        defer { h.close() }
        try await wait { h.pane.domReady && h.images.started > 0 }
        _ = await h.measure()
        let pending = await h.className()
        XCTAssertTrue(pending.contains(HTMLBodyLayout.layoutImageClass), pending)
        XCTAssertFalse(pending.contains(HTMLBodyLayout.failedImageClass), pending)
        let pendingStates = try await h.imageStates()
        XCTAssertEqual(pendingStates.images["card"]?["altText"] as? String, "",
                       "still loading: no alt text in its place")
        XCTAssertNotEqual(pendingStates.images["card"]?["display"] as? String, "none")
        h.images.fail()
        var after = ""
        let deadline = Date().addingTimeInterval(10)
        while !after.contains(HTMLBodyLayout.failedImageClass), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            after = await h.className()
        }
        XCTAssertTrue(after.contains(HTMLBodyLayout.failedImageClass), after)
    }

    // MARK: Failed images: no broken-image icon (Gmail-like)

    /// The allowed CSP of the app with the test's image scheme added, so the
    /// host below can answer 404 or a non-image body; https stays allowed.
    private var allowedCSPWithTestScheme: String {
        HTMLBodyCSP.metaTag(allowRemoteImages: true).replacingOccurrences(
            of: "img-src data: cid: https:", with: "img-src data: cid: https: mmimg:")
    }

    private func waitForFailures(_ h: Harness, ids: [String]) async throws
        -> (allowed: Bool, images: [String: [String: Any]]) {
        var states = try await h.imageStates()
        let deadline = Date().addingTimeInterval(10)
        while ids.contains(where: { states.images[$0]?["failed"] as? Bool != true }), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            _ = await h.measure()
            states = try await h.imageStates()
        }
        return states
    }

    /// With images allowed, a failed image without alt text (404, a body
    /// that is not an image, an `http:` URL whose https form fails, a `cid:`
    /// part that is missing) is hidden with its box kept, so WebKit draws no
    /// broken-image icon; an image with alt text is replaced by its alt text
    /// (`testFailedImageWithAltShowsOnlyItsTextAndCollapses`); an image still
    /// loading from a dead host is left alone.
    func testFailedImagesWithoutAltAreHiddenWithTheirBoxKept() async throws {
        let html = """
        <p>Grazie per il tuo acquisto!</p>
        <img id="missing" src="mmimg://images.example/404.png" width="80" height="30">
        <img id="notimage" src="mmimg://images.example/page.png" alt="" width="60" height="20">
        <img id="http" src="http://images.example/logo.png" width="120" height="40">
        <img id="cid" src="cid:missing-part@example">
        <img id="withalt" src="mmimg://images.example/gone.png" alt="SumUp" width="90" height="30">
        <img id="dead" src="mmimg://images.example/dead.png" width="50" height="50">
        <p>Totale</p>
        """
        let h = load(html, cspMeta: allowedCSPWithTestScheme, immediate: [
            "/404.png": (404, "text/plain", Data()),
            "/page.png": (200, "text/html", Data("<html>not an image</html>".utf8)),
            "/gone.png": (404, "text/plain", Data()),
        ])
        defer { h.close() }
        try await wait { h.pane.domReady }
        _ = await h.measure()
        let hidden = ["missing", "notimage", "http", "cid"]
        let states = try await waitForFailures(h, ids: hidden + ["withalt"])
        XCTAssertTrue(states.allowed, "the allowed CSP is detected")
        for id in hidden {
            let image = try XCTUnwrap(states.images[id], id)
            XCTAssertEqual(image["failed"] as? Bool, true, "\(id) failed: \(image)")
            XCTAssertEqual(image["visibility"] as? String, "hidden", "\(id): no broken-image icon: \(image)")
            XCTAssertNotEqual(image["display"] as? String, "none", "\(id): its box stays")
        }
        XCTAssertEqual(states.images["http"]?["width"] as? Int, 120, "the authored width is kept")
        let withAlt = try XCTUnwrap(states.images["withalt"])
        XCTAssertEqual(withAlt["failed"] as? Bool, true)
        XCTAssertEqual(withAlt["display"] as? String, "none", "alt text instead of the image")
        XCTAssertEqual(withAlt["altText"] as? String, "SumUp")
        let dead = try XCTUnwrap(states.images["dead"])
        XCTAssertEqual(dead["failed"] as? Bool, false, "still loading: not failed")
        XCTAssertEqual(dead["visibility"] as? String, "visible")
    }

    /// Defect seen on a newsletter whose images failed: big dashed boxes at
    /// the authored size with WebKit's "?" icon and the alt text in a
    /// corner. As in Gmail on the web: the alt text only, small, the box
    /// collapsed to it (a link stays a link), as text (never markup), and
    /// the body re-measured shorter.
    func testFailedImageWithAltShowsOnlyItsTextAndCollapses() async throws {
        let html = """
        <table width="600"><tr><td style="font-size:0">\
        <a href="https://www.example.com/"><img id="logo" src="mmimg://images.example/logo.png" \
        alt="Logo: Example Publisher" width="600" height="400"></a></td></tr>\
        <tr><td><img id="hero" src="mmimg://images.example/hero.png" alt="  Hero\n image  " \
        width="600" height="500" style="background-color:#123456"></td></tr>\
        <tr><td><img id="markup" src="mmimg://images.example/m.png" alt="<b>bold</b>" width="300" height="300"></td></tr>\
        </table><p>Congratulations</p>
        """
        let h = load(html, cspMeta: allowedCSPWithTestScheme, immediate: [
            "/logo.png": (404, "text/plain", Data()),
            "/hero.png": (403, "text/plain", Data()),
            "/m.png": (200, "text/html", Data("<html></html>".utf8)),
        ])
        defer { h.close() }
        try await wait { h.pane.domReady }
        _ = await h.measure()
        let states = try await waitForFailures(h, ids: ["logo", "hero", "markup"])
        for id in ["logo", "hero", "markup"] {
            let image = try XCTUnwrap(states.images[id], id)
            XCTAssertEqual(image["display"] as? String, "none", "\(id): no box, no icon: \(image)")
            let altHeight = try XCTUnwrap(image["altHeight"] as? Int)
            XCTAssertGreaterThan(altHeight, 0, "\(id): the alt text shows")
            XCTAssertLessThan(altHeight, 40, "\(id): small, not the authored height")
        }
        XCTAssertEqual(states.images["logo"]?["altText"] as? String, "Logo: Example Publisher")
        XCTAssertEqual(states.images["logo"]?["altInLink"] as? Bool, true, "still the link")
        XCTAssertEqual(states.images["hero"]?["altText"] as? String, "Hero image", "whitespace folded")
        XCTAssertEqual(states.images["hero"]?["altBackground"] as? String, "rgba(0, 0, 0, 0)",
                       "the image's own background is not copied")
        XCTAssertEqual(states.images["markup"]?["altText"] as? String, "<b>bold</b>", "text, not markup")
        XCTAssertEqual(states.images["markup"]?["altElements"] as? Int, 0)
        // The body measures to the text, not to 1200 px of boxes.
        var height: CGFloat = 0
        let deadline = Date().addingTimeInterval(5)
        repeat {
            height = await h.measure() ?? 0
            if height > 0, height < 300 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        XCTAssertLessThan(height, 300, "collapsed boxes re-measure the body")

        // The census the diagnostics line is made of: counts only.
        let result: Any? = await withCheckedContinuation { done in
            h.webView.evaluateJavaScript(HTMLBodyLayout.imageCensusJS) { value, _ in
                done.resume(returning: value)
            }
        }
        let census = try XCTUnwrap(RemoteImageCensus(scriptResult: result))
        XCTAssertTrue(census.allowed)
        XCTAssertEqual(census.failed, 3)
        XCTAssertEqual(census.altShown, 3)
        XCTAssertEqual(census.unresolvable, 3, "the test scheme is neither https nor http")
        XCTAssertTrue(census.hasFailures)
        XCTAssertFalse(census.text.contains("example"), census.text)
    }

    /// `http:` and `//host/…` images, as Gmail shows them: requested over
    /// https, never over http. The scanner gives `//` URLs the https scheme
    /// in the allowed document (they have no base to resolve against);
    /// `upgrade-insecure-requests` in the allowed CSP upgrades `http:`. Each listener
    /// accepting a connection proves an https request: plain http to it is
    /// refused by the CSP before any connection. The blocked variant asks
    /// neither.
    func testInsecureImagesAreRequestedOverHTTPS() async throws {
        let scanned = try SilentTLSHost()
        let upgraded = try SilentTLSHost()
        let blocked = try SilentTLSHost()
        let scannedPort = try await scanned.start()
        let upgradedPort = try await upgraded.start()
        let blockedPort = try await blocked.start()
        defer { scanned.stop(); upgraded.stop(); blocked.stop() }

        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        func open(_ html: String, allow: Bool) -> WKWebView {
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 400),
                                    configuration: HTMLWebViewPool.makeConfiguration())
            window.contentView?.addSubview(webView)
            let document = HTMLBodyDocument.assemble(
                html: html, cspMeta: HTMLBodyCSP.metaTag(allowRemoteImages: allow),
                styleCSS: HTMLBodyDarkMode.injectedCSS(fontScale: 1))
            webView.loadHTMLString(document, baseURL: nil)
            return webView
        }
        let allowedView = open("""
            <img src="//127.0.0.1:\(scannedPort)/a.png" width="10" height="10">\
            <img src="http://127.0.0.1:\(upgradedPort)/b.png" width="10" height="10">
            """, allow: true)
        let blockedView = open(
            "<img src=\"http://127.0.0.1:\(blockedPort)/c.png\" width=\"10\" height=\"10\">",
            allow: false)
        defer {
            allowedView.removeFromSuperview()
            blockedView.removeFromSuperview()
        }

        try await wait(seconds: 8) { scanned.accepted > 0 && upgraded.accepted > 0 }
        XCTAssertGreaterThan(scanned.accepted, 0, "protocol-relative image requested over https")
        XCTAssertGreaterThan(upgraded.accepted, 0, "http image upgraded by the CSP")
        XCTAssertEqual(blocked.accepted, 0, "images blocked: nothing is asked")
    }

    /// Records the navigations the document asks for, and allows none but
    /// the synthetic initial load (as the reading pane's coordinator).
    private final class LinkRecorder: NSObject, WKNavigationDelegate {
        var requested: [URL] = []
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            if url == nil || url?.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            if let url { requested.append(url) }
            decisionHandler(.cancel)
        }
    }

    /// `upgrade-insecure-requests` upgrades image requests, not links: a
    /// click on an `http:` link reaches the app as that `http:` URL.
    func testLinksAreNotUpgraded() async throws {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let recorder = LinkRecorder()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 400),
                                configuration: HTMLWebViewPool.makeConfiguration())
        webView.navigationDelegate = recorder
        window.contentView?.addSubview(webView)
        defer { webView.removeFromSuperview() }
        let document = HTMLBodyDocument.assemble(
            html: "<a id=\"l\" href=\"http://www.example.com/page?a=1\">Read</a>",
            cspMeta: HTMLBodyCSP.metaTag(allowRemoteImages: true),
            styleCSS: HTMLBodyDarkMode.injectedCSS(fontScale: 1))
        webView.loadHTMLString(document, baseURL: nil)
        try await wait { !webView.isLoading }
        try await Task.sleep(nanoseconds: 200_000_000)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript("document.getElementById('l').click(); 1") { _, _ in
                done.resume()
            }
        }
        try await wait { !recorder.requested.isEmpty }
        XCTAssertEqual(recorder.requested.map(\.absoluteString), ["http://www.example.com/page?a=1"])
    }

    /// Dark mode stamps every element once, at document end; the alt text
    /// comes later and must take the stamp of the fill it sits on, so it is
    /// dark text on a white newsletter card, not light grey on white.
    func testAltTextContrastsWithItsCardInDarkMode() async throws {
        let html = """
        <table style="background-color:#ffffff" width="600"><tr><td>\
        <img id="logo" src="mmimg://images.example/gone.png" alt="Logo" width="300" height="100">\
        </td></tr></table>
        """
        let h = load(html, cspMeta: allowedCSPWithTestScheme,
                     immediate: ["/gone.png": (404, "text/plain", Data())], dark: true)
        defer { h.close() }
        try await wait { h.pane.domReady }
        _ = await h.measure()
        let states = try await waitForFailures(h, ids: ["logo"])
        let logo = try XCTUnwrap(states.images["logo"])
        XCTAssertEqual(logo["altText"] as? String, "Logo")
        let altClass = try XCTUnwrap(logo["altClass"] as? String)
        XCTAssertTrue(altClass.contains(HTMLBodyDarkMode.fgOnLightClass), altClass)
        XCTAssertEqual(logo["altColor"] as? String, "rgb(34, 34, 34)", "dark text on the white card")
    }

    /// A loaded image is never taken for a failed one, even when it has no
    /// intrinsic size (an SVG with only a viewBox can report naturalWidth 0):
    /// its own load event decides.
    func testLoadedImageWithoutIntrinsicSizeIsNotFailed() async throws {
        let svg = "data:image/svg+xml;charset=utf-8,%3Csvg%20xmlns%3D%27http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%27"
            + "%20viewBox%3D%270%200%2010%2010%27%3E%3Crect%20width%3D%2710%27%20height%3D%2710%27%2F%3E%3C%2Fsvg%3E"
        let h = load("<p>Chart</p><img id=\"svg\" src=\"\(svg)\" alt=\"Chart\"><p>Tail</p>",
                     cspMeta: allowedCSPWithTestScheme)
        defer { h.close() }
        try await wait { h.pane.domReady }
        var states = try await h.imageStates()
        let deadline = Date().addingTimeInterval(5)
        while states.images["svg"]?["complete"] as? Bool != true, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            states = try await h.imageStates()
        }
        _ = await h.measure()
        states = try await h.imageStates()
        let image = try XCTUnwrap(states.images["svg"])
        XCTAssertEqual(image["complete"] as? Bool, true)
        XCTAssertEqual(image["failed"] as? Bool, false, "\(image)")
        XCTAssertNotEqual(image["display"] as? String, "none", "\(image)")
        XCTAssertEqual(image["altText"] as? String, "")
    }

    /// Message content cannot steer the app's image script: named elements
    /// that shadow `document.documentElement` / `document.querySelectorAll`
    /// (and a form's `classList`) change neither the images-allowed decision
    /// nor the census.
    func testNamedElementsCannotSteerTheImageScripts() async throws {
        let html = """
        <img name="documentElement" class="\(HTMLBodyLayout.imagesAllowedClass)" src="cid:none@x">\
        <img name="querySelectorAll" src="cid:none2@x">\
        <img name="querySelector" src="cid:none3@x">\
        <img name="createElement" src="cid:none4@x">\
        <img name="body" src="cid:none5@x"><img name="body" src="cid:none6@x">\
        <form><input name="classList"><input name="parentNode"><input name="style">\
        <input name="getBoundingClientRect"><input name="tagName">\
        <img id="blocked" src="https://images.example/hero.png" alt="x" width="300" height="100"></form>\
        <div style="height:600px">tall</div>
        """
        // Tall enough (>= 200 px) for the viewport-height walk to run.
        let h = load(html, cspMeta: HTMLBodyCSP.metaTag(allowRemoteImages: false), height: 400)
        defer { h.close() }
        try await wait { h.pane.domReady }
        _ = await h.measure()
        let script = """
        (function(){
          var root = Object.getOwnPropertyDescriptor(Document.prototype, 'documentElement').get.call(document);
          var img = Document.prototype.getElementById.call(document, 'blocked');
          var prev = img.previousElementSibling;
          return JSON.stringify({
            allowed: root.classList.contains('\(HTMLBodyLayout.imagesAllowedClass)'),
            failed: img.classList.contains('\(HTMLBodyLayout.failedImageClass)'),
            altShown: !!prev && prev.classList.contains('\(HTMLBodyLayout.altTextClass)'),
            display: getComputedStyle(img).display
          });
        })()
        """
        var state: [String: Any] = [:]
        let deadline = Date().addingTimeInterval(10)
        repeat {
            _ = await h.measure()
            let result: Any? = await withCheckedContinuation { done in
                h.webView.evaluateJavaScript(script) { value, _ in done.resume(returning: value) }
            }
            if let text = result as? String, let data = text.data(using: .utf8) {
                state = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            if state["failed"] as? Bool == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        XCTAssertEqual(state["allowed"] as? Bool, false, "\(state)")
        XCTAssertEqual(state["failed"] as? Bool, true, "\(state)")
        XCTAssertEqual(state["altShown"] as? Bool, false, "blocked keeps its placeholder: \(state)")
        XCTAssertNotEqual(state["display"] as? String, "none")
        let measured = await h.measure()
        let height = try XCTUnwrap(measured, "the install still reports a height")
        XCTAssertGreaterThan(height, 600, "measured past the 600 px block: \(height)")

        let census: Any? = await withCheckedContinuation { done in
            h.webView.evaluateJavaScript(HTMLBodyLayout.imageCensusJS) { value, _ in
                done.resume(returning: value)
            }
        }
        let parsed = try XCTUnwrap(RemoteImageCensus(scriptResult: census), "the census still runs")
        XCTAssertFalse(parsed.allowed)
        XCTAssertEqual(parsed.blocked, 1, "\(parsed.text)")
        XCTAssertEqual(parsed.failed, 6, "the missing cid: parts: \(parsed.text)")
    }

    /// With images blocked (Ask each time, Spam), a blocked image keeps the
    /// dashed blocked-image placeholder.
    func testBlockedImagesKeepTheirPlaceholder() async throws {
        let html = """
        <p>Newsletter</p>
        <img id="blocked" src="https://images.example/hero.png" alt="x" width="300" height="100">
        """
        let h = load(html, cspMeta: HTMLBodyCSP.metaTag(allowRemoteImages: false))
        defer { h.close() }
        try await wait { h.pane.domReady }
        _ = await h.measure()
        let states = try await waitForFailures(h, ids: ["blocked"])
        XCTAssertFalse(states.allowed)
        let image = try XCTUnwrap(states.images["blocked"])
        XCTAssertEqual(image["failed"] as? Bool, true, "\(image)")
        XCTAssertEqual(image["visibility"] as? String, "visible", "the placeholder is shown")
        XCTAssertEqual(image["width"] as? Int, 300)
        XCTAssertEqual(image["altText"] as? String, "", "blocked on purpose: no alt text in its place")
        XCTAssertNotEqual(image["display"] as? String, "none")
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
            .appendingPathComponent("dreamail-latency-\(UUID().uuidString)", isDirectory: true)
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
