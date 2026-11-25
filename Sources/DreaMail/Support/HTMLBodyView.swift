import AppKit
import SwiftUI
import WebKit

/// Sandboxed HTML rendering: page JavaScript disabled; remote images blocked
/// by a WebKit content rule plus CSP unless the user opts in (per message or
/// Settings → Appearance default).
/// Sizes itself to its content. External links open in the default browser.
///
/// Web views are drawn from `HTMLWebViewPool` (recycle + shared ephemeral
/// store + optional pre-rendered neighbors) so expanding/collapsing cards and
/// up/down thread browses do not thrash WKWebView creation.
///
/// Content swaps keep the outgoing painted view visible until the incoming
/// view has painted (or is a pre-rendered claim). Settled heights are cached
/// per `contentID` so re-open does not reflow after paint. Transitions are a
/// short opacity fade (≤0.1s) or none — never a slide.
///
/// Height updates come from a `ResizeObserver` + image load/error handlers
/// (`HTMLBodyLayout`) posting to a `WKScriptMessageHandler`, not a fixed
/// multi-second poll. Blocked/failed images keep capped authored dimensions
/// so table-based transactional layouts do not collapse under Ask policy.
struct HTMLBodyView: NSViewRepresentable {
    /// Stable O(1)-sized identity supplied by the message card. Never derive
    /// this by hashing the untrusted, potentially multi-megabyte HTML string.
    let contentID: String
    let html: String
    /// Pre-assembled document from `ThreadDetailRepository` (CSP + CSS already
    /// injected). When present, render skips `HTMLBodyDocument.assemble`.
    var preassembledDocument: String? = nil
    /// Prep documents for `html` at this font scale, when the card has them.
    /// With no `preassembledDocument` (allowed variant not memoized yet), the
    /// coordinator builds through these off-main so the memo fills for the
    /// next mount. Never read on the main actor beyond passing it along.
    var documents: MessageHTMLDocuments? = nil
    /// Which variant of `documents` `html` is (authored head vs full body).
    var documentIsAuthored: Bool = false
    let allowRemoteImages: Bool
    var fontScale: Double = 1.0
    @Binding var height: CGFloat
    /// Fired once the first stable height for the current document is known
    /// (ResizeObserver settle). Used to arm neighbor pre-renders.
    var onSettled: (() -> Void)? = nil
    /// Fired with the document's load key once the web view's own load of
    /// it ended (window load or failure; a claimed pre-render already has),
    /// or `HTMLBodyLayout.loadBound` after DOM ready when it has not (an
    /// image that never completes). The card starts the background image
    /// fetch only then, so the app's requests never run alongside the web
    /// view's. The key carries the CSP variant: a Load-images click is a
    /// new load of the same content id.
    var onLoadFinished: ((HTMLBodyLoadKey) -> Void)? = nil

    /// Cross-fade when swapping painted WebViews. Project style: fade only,
    /// never a slide; keep well under 100ms.
    private static let swapFadeDuration: TimeInterval = 0.08

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        context.coordinator.container = container
        context.coordinator.contentID = contentID
        context.coordinator.onSettled = onSettled
        context.coordinator.onLoadFinished = onLoadFinished

        let heightBinding = _height
        context.coordinator.setHeight = { heightBinding.wrappedValue = $0 }
        // Cached height keeps the card frame stable before the first paint.
        // Applied async (SwiftUI forbids state writes mid-update) and only if
        // no real measurement landed first — a fast paint must not be
        // overwritten by a stale placeholder.
        if let cached = HTMLBodyHeightCacheStore.height(
            contentID: contentID, fontScale: fontScale,
            width: HTMLBodyHeightCacheStore.lastLayoutWidth) {
            let expectedContentID = contentID
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard let coordinator,
                      coordinator.contentID == expectedContentID,
                      coordinator.heightUpdateCount == 0 else { return }
                heightBinding.wrappedValue = cached
            }
        }

        let key = HTMLBodyLoadKey(
            contentID: contentID,
            allowRemoteImages: allowRemoteImages,
            fontScale: fontScale)
        context.coordinator.loadedKey = key

        if let ready = HTMLWebViewPool.claimPrerendered(for: key) {
            context.coordinator.attach(
                ready, in: container, alreadyPainted: true, fade: false)
            context.coordinator.beginRender(
                byteCount: html.utf8.count,
                variant: contentID.hasSuffix(":authored") ? "authored" : "full",
                prerenderHit: true)
            context.coordinator.acceptsHeightReports = true
            context.coordinator.installLayoutAndMeasure(ready)
            context.coordinator.loadDidEnd()
        } else {
            let webView = HTMLWebViewPool.dequeue()
            context.coordinator.attach(
                webView, in: container, alreadyPainted: false, fade: false)
            context.coordinator.beginRender(
                byteCount: html.utf8.count,
                variant: contentID.hasSuffix(":authored") ? "authored" : "full",
                prerenderHit: false)
            context.coordinator.loadDocument(
                html: html, preassembled: preassembledDocument,
                documents: documents, authored: documentIsAuthored,
                allowRemoteImages: allowRemoteImages,
                fontScale: fontScale, in: webView)
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.container = container
        context.coordinator.contentID = contentID
        context.coordinator.onSettled = onSettled
        context.coordinator.onLoadFinished = onLoadFinished
        // Refresh the binding callback even when the document identity did not
        // change. Capture the Binding only — capturing `self` retains `html`.
        let heightBinding = _height
        context.coordinator.setHeight = { heightBinding.wrappedValue = $0 }

        let key = HTMLBodyLoadKey(
            contentID: contentID,
            allowRemoteImages: allowRemoteImages,
            fontScale: fontScale)
        guard context.coordinator.loadedKey != key else { return }

        // Applied async like makeNSView's placeholder: updateNSView runs
        // inside SwiftUI's update pass, where a synchronous binding write is
        // undefined behavior. Guarded so a measurement that lands first wins.
        let layoutWidth = container.bounds.width
        if let cached = HTMLBodyHeightCacheStore.height(
            contentID: contentID, fontScale: fontScale,
            width: layoutWidth > 0 ? layoutWidth : nil) {
            let expectedContentID = contentID
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard let coordinator,
                      coordinator.contentID == expectedContentID,
                      coordinator.heightUpdateCount == 0 else { return }
                heightBinding.wrappedValue = cached
            }
        }

        context.coordinator.loadedKey = key
        context.coordinator.beginRender(
            byteCount: html.utf8.count,
            variant: contentID.hasSuffix(":authored") ? "authored" : "full",
            prerenderHit: false)

        if let ready = HTMLWebViewPool.claimPrerendered(for: key) {
            context.coordinator.swap(
                to: ready, alreadyPainted: true, html: html,
                preassembled: preassembledDocument,
                documents: documents, authored: documentIsAuthored,
                allowRemoteImages: allowRemoteImages, fontScale: fontScale)
        } else {
            let incoming = HTMLWebViewPool.dequeue()
            context.coordinator.swap(
                to: incoming, alreadyPainted: false, html: html,
                preassembled: preassembledDocument,
                documents: documents, authored: documentIsAuthored,
                allowRemoteImages: allowRemoteImages, fontScale: fontScale)
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loadedKey: HTMLBodyLoadKey?
        var setHeight: ((CGFloat) -> Void)?
        var onSettled: (() -> Void)?
        var onLoadFinished: ((HTMLBodyLoadKey) -> Void)?
        var contentID: String = ""
        weak var container: NSView?
        private(set) var current: PassthroughWebView?
        private var incoming: PassthroughWebView?
        private var loadToken = UUID()
        private var heightStability = HTMLHeightStability()
        /// Read by the makeNSView cached-height fallback: a stale cached
        /// placeholder must never overwrite a real measurement.
        private(set) var heightUpdateCount = 0
        private var renderInterval: PerfMetrics.Interval?
        private var renderTimeout: DispatchWorkItem?
        var acceptsHeightReports = false
        private var navigationGate = HTMLNavigationIdentityGate()
        private var pendingReveal = false
        private var settledNotified = false
        /// Measure before window load (`HTMLDOMReadyGate`).
        private var domReadyGate = HTMLDOMReadyGate()
        /// `open.html` timing (no mail data): what installed the measure
        /// that produced the first height, and when.
        private var renderStart: CFAbsoluteTime = 0
        private var firstHeightMs: Int?
        private var measuredBy = "load"
        /// The document's load ended (or its bound passed): reported once.
        private var loadEndNotified = false
        /// Heights go to `HTMLBodyHeightCacheStore` only once the load ended
        /// (or its bound passed): a height measured mid-load, before the
        /// images, must not size the next open's first paint.
        private var heightCacheAllowed = false
        private var pendingCachedHeight: (height: CGFloat, width: CGFloat)?
        /// Bumped on every swap/dismantle so an in-flight fade completion
        /// from a superseded swap cannot recycle views or promote `current`.
        private var swapGeneration = 0
        /// Bumped per `loadDocument` / dismantle so an off-main assembly that
        /// finishes after the card moved on never navigates a reused view.
        private var assembleGeneration = 0
        /// Generation of an off-main assembly that has not navigated yet.
        /// The render timeout must not reveal a pooled view while its
        /// document is still being built: that view may hold foreign DOM.
        private var pendingAssemblyGeneration: Int?

        func attach(_ webView: PassthroughWebView, in container: NSView,
                    alreadyPainted: Bool, fade: Bool) {
            webView.navigationDelegate = self
            webView.installHeightHandler(self)
            webView.setValue(false, forKey: "drawsBackground")
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            // Stolen pre-renders still paint foreign DOM until their own load
            // commits — never show them at alpha 1. Free-list / new views are
            // blank and may appear immediately (no slower path regression).
            let hideUntilOwnPaint = !alreadyPainted
                && (webView.hasForeignContent || (fade && current != nil))
            webView.alphaValue = hideUntilOwnPaint ? 0 : 1
            webView.hasForeignContent = false
            container.addSubview(webView)
            current = webView
            pendingReveal = !alreadyPainted
        }

        /// Keep outgoing content visible until `next` is painted (or already is).
        /// Stop height reporting and return a view to the pool. Always runs
        /// teardown so freeze globals / ResizeObserver cannot linger on a
        /// recycled view (Fable #8 — was previously only on `current` dismantle).
        private func recycle(_ webView: PassthroughWebView,
                             removeFromHierarchy: Bool = false) {
            webView.navigationDelegate = nil
            webView.evaluateJavaScript(
                HTMLBodyLayout.teardownJS, completionHandler: nil)
            webView.removeHeightHandlerIfNeeded()
            if removeFromHierarchy {
                webView.removeFromSuperview()
            }
            HTMLWebViewPool.recycle(webView)
        }

        func swap(to next: PassthroughWebView, alreadyPainted: Bool,
                  html: String, preassembled: String? = nil,
                  documents: MessageHTMLDocuments? = nil, authored: Bool = false,
                  allowRemoteImages: Bool, fontScale: Double) {
            swapGeneration &+= 1
            // Invalidate any off-main assembly aimed at the outgoing view. A
            // pre-render hit does not call loadDocument, and the pool can hand
            // the outgoing view back to this coordinator before the stale
            // assembly lands, which would load the old body over the new one.
            assembleGeneration &+= 1
            guard let container else {
                recycle(next)
                return
            }
            // Abandon any in-flight incoming load.
            if let abandoned = incoming, abandoned !== current {
                recycle(abandoned)
            }
            incoming = next
            next.navigationDelegate = self
            next.installHeightHandler(self)
            next.setValue(false, forKey: "drawsBackground")
            next.frame = container.bounds
            next.autoresizingMask = [.width, .height]
            // Stay invisible until first paint so the outgoing body never blanks.
            // Also covers stolen pre-renders still holding foreign DOM.
            next.alphaValue = 0
            next.hasForeignContent = false
            container.addSubview(next, positioned: .above, relativeTo: current)
            pendingReveal = true
            settledNotified = false

            if alreadyPainted {
                acceptsHeightReports = true
                installLayoutAndMeasure(next)
                revealIncoming(animated: true)
                loadDidEnd()
            } else {
                loadDocument(
                    html: html, preassembled: preassembled,
                    documents: documents, authored: authored,
                    allowRemoteImages: allowRemoteImages,
                    fontScale: fontScale, in: next)
            }
        }

        func beginRender(byteCount: Int, variant: String, prerenderHit: Bool) {
            finishRender(reason: "superseded")
            acceptsHeightReports = false
            navigationGate.reset()
            heightStability.reset()
            heightUpdateCount = 0
            settledNotified = false
            domReadyGate.reset()
            loadEndNotified = false
            heightCacheAllowed = false
            pendingCachedHeight = nil
            renderStart = CFAbsoluteTimeGetCurrent()
            firstHeightMs = nil
            measuredBy = prerenderHit ? "prerender" : "load"
            renderInterval = PerfMetrics.begin(
                .openHTML,
                meta: "bytes=\(byteCount) variant=\(variant) prerender=\(prerenderHit ? 1 : 0)")

            // ResizeObserver normally produces a confirming height quickly.
            // End diagnostics even for malformed documents that never settle.
            // Views stay hidden until their first height report (pooled views
            // may hold a stale DOM until the blank load commits), so also
            // reveal here: a document that never reports must not stay
            // invisible past the timeout.
            armRenderTimeout()
        }

        private func armRenderTimeout() {
            let timeout = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Assembly still running off-main for this render: wait for
                // it instead of revealing a view that has not navigated yet.
                if let pending = self.pendingAssemblyGeneration,
                   pending == self.assembleGeneration {
                    self.armRenderTimeout()
                    return
                }
                self.revealIncoming(animated: false)
                self.finishRender(reason: "timeout")
            }
            renderTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        }

        func loadDocument(html: String, preassembled: String? = nil,
                          documents: MessageHTMLDocuments? = nil,
                          authored: Bool = false,
                          allowRemoteImages: Bool,
                          fontScale: Double, in webView: WKWebView) {
            assembleGeneration &+= 1
            let csp = HTMLBodyCSP.metaTag(allowRemoteImages: allowRemoteImages)
            let css = HTMLBodyDarkMode.injectedCSS(fontScale: fontScale)
            let trustedFallback = {
                HTMLBodyDocument.trustedWrapper(
                    html: html, cspMeta: csp, styleCSS: css)
            }
            // Common path: the repository (or CID prep) already assembled it.
            if let preassembled {
                load(document: preassembled, trustedFallback: trustedFallback,
                     allowRemoteImages: allowRemoteImages, in: webView)
                return
            }
            // Fallback (allowed variant not memoized yet, font-scale
            // mismatch, oversized after explicit approve, no prep): assemble
            // off the main actor — this is whole-body string work, MBs for
            // CID-inlined mail. Prefer the prep's memo so the next mount of
            // this card is a lookup. The view stays hidden until its first
            // height report, so the extra hop shows no blank frame.
            let generation = assembleGeneration
            pendingAssemblyGeneration = generation
            let docs = documents
            Task { @MainActor [weak self, weak webView] in
                let document = await Task.detached(priority: .userInitiated) {
                    () -> String in
                    if let docs, let built = docs.document(
                        authored: authored, allowRemoteImages: allowRemoteImages) {
                        return built
                    }
                    return HTMLBodyDocument.assemble(
                        html: html, cspMeta: csp, styleCSS: css)
                }.value
                if self?.pendingAssemblyGeneration == generation {
                    self?.pendingAssemblyGeneration = nil
                }
                guard let self, let webView,
                      self.assembleGeneration == generation,
                      webView === self.incoming || webView === self.current
                else { return }
                self.load(document: document, trustedFallback: trustedFallback,
                          allowRemoteImages: allowRemoteImages, in: webView)
            }
        }

        /// Apply/remove the network-level remote-image rule before navigating.
        /// A generation token prevents a late compile callback from mutating a
        /// recycled view or superseding a newer Load-images request.
        ///
        /// The rule list is compiled once at app launch (`prepareAtLaunch`);
        /// the common path installs the cached list synchronously so message
        /// opens never wait on WebKit compilation.
        func load(document: String, trustedFallback: @escaping () -> String,
                  allowRemoteImages: Bool, in webView: WKWebView) {
            let token = UUID()
            loadToken = token
            let controller = webView.configuration.userContentController
            controller.removeAllContentRuleLists()

            if allowRemoteImages {
                startNavigation(webView, document: document)
                return
            }

            if let ready = HTMLRemoteImageBlocker.preparedRuleList {
                controller.add(ready)
                startNavigation(webView, document: document)
                return
            }

            HTMLRemoteImageBlocker.ruleList { [weak self, weak webView] ruleList in
                guard let self, let webView, self.loadToken == token else { return }
                let controller = webView.configuration.userContentController
                controller.removeAllContentRuleLists()
                if let ruleList {
                    controller.add(ruleList)
                    self.startNavigation(webView, document: document)
                } else {
                    // Compilation is expected to be infallible for the static
                    // rule, but privacy fails closed if WebKit rejects it.
                    self.startNavigation(webView, document: trustedFallback())
                }
            }
        }

        private func startNavigation(_ webView: WKWebView, document: String) {
            domReadyGate.reset()
            let navigation = webView.loadHTMLString(document, baseURL: nil)
            navigationGate.didStart(navigation)
        }

        /// Drop height callbacks and recycle live views when the representable
        /// leaves the hierarchy.
        func dismantle() {
            swapGeneration &+= 1
            assembleGeneration &+= 1
            loadToken = UUID()
            loadedKey = nil
            setHeight = nil
            onSettled = nil
            acceptsHeightReports = false
            navigationGate.reset()
            domReadyGate.reset()
            onLoadFinished = nil
            finishRender(reason: "detached")
            heightStability.reset()
            pendingReveal = false

            if let incoming, incoming !== current {
                recycle(incoming)
            }
            incoming = nil
            if let current {
                recycle(current)
            }
            self.current = nil
            container = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigationGate.accepts(navigation) else { return }
            // Only the active incoming (or sole current) navigation counts.
            guard webView === incoming || (incoming == nil && webView === current)
            else { return }
            // Primary contrast pass runs as WKUserScript at document-end
            // (WebViewPool) for every navigation, including recycled views.
            // Re-run when DOM ready already installed it (safe to re-run).
            domReadyGate.didFinishLoad()
            acceptsHeightReports = true
            installLayoutAndMeasure(webView)
            loadDidEnd()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard navigationGate.accepts(navigation) else { return }
            guard webView === incoming || (incoming == nil && webView === current)
            else { return }
            domReadyGate.didCommit()
        }

        /// The document is parsed (`HTMLBodyLayout.domReadyJS`): measure
        /// after a short grace unless window load comes first, so a slow
        /// image host never holds the body at its placeholder height.
        private func domReady(in webView: WKWebView) {
            guard webView === incoming || (incoming == nil && webView === current),
                  let generation = domReadyGate.domReady() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + HTMLBodyLayout.domReadyGrace) {
                [weak self, weak webView] in
                guard let self, let webView,
                      webView === self.incoming
                        || (self.incoming == nil && webView === self.current),
                      self.domReadyGate.graceEnded(generation: generation) else { return }
                self.measuredBy = "domReady"
                self.acceptsHeightReports = true
                self.installLayoutAndMeasure(webView)
            }
            // A page whose load never ends (one image that never completes)
            // still counts as loaded after the bound: its other images get
            // cached, and the measure it has is the one worth keeping.
            DispatchQueue.main.asyncAfter(deadline: .now() + HTMLBodyLayout.loadBound) {
                [weak self, weak webView] in
                guard let self, let webView,
                      webView === self.incoming
                        || (self.incoming == nil && webView === self.current),
                      self.domReadyGate.loadBoundReached(generation: generation) else { return }
                self.loadDidEnd()
            }
        }

        /// The active document's own load ended, its bound passed, or a
        /// painted pre-render was claimed: heights may be cached from now,
        /// and the card hears it once. Async: may run inside a SwiftUI update.
        func loadDidEnd() {
            heightCacheAllowed = true
            if let pending = pendingCachedHeight {
                pendingCachedHeight = nil
                storeHeight(pending.height, width: pending.width)
            }
            guard !loadEndNotified, let key = loadedKey else { return }
            loadEndNotified = true
            let callback = onLoadFinished
            DispatchQueue.main.async { callback?(key) }
            logImageCensus()
        }

        /// One diagnostics line when an image of the document on screen
        /// failed (`RemoteImageCensus`: counts and URL kinds, no URL).
        private func logImageCensus() {
            guard let webView = incoming ?? current else { return }
            webView.evaluateJavaScript(HTMLBodyLayout.imageCensusJS) { result, _ in
                guard let census = RemoteImageCensus(scriptResult: result),
                      census.hasFailures else { return }
                DiagnosticLog.remoteImages(census)
            }
        }

        private func storeHeight(_ height: CGFloat, width: CGFloat) {
            guard !contentID.isEmpty, let key = loadedKey, width > 0 else { return }
            HTMLBodyHeightCacheStore.store(
                height, contentID: contentID, fontScale: key.fontScale, width: width)
        }

        func installLayoutAndMeasure(_ webView: WKWebView) {
            webView.evaluateJavaScript(HTMLBodyLayout.installLayoutAndMeasureJS) { [weak self] result, _ in
                self?.applyMeasuredHeight(result, from: webView)
            }
        }

        private func applyMeasuredHeight(_ result: Any?, from webView: WKWebView? = nil) {
            guard acceptsHeightReports else { return }
            // During a double-buffered swap the coordinator's contentID is
            // already the incoming document's, so only the incoming view may
            // publish or cache heights — the outgoing view's ResizeObserver
            // would poison the new card's frame and height cache.
            if incoming != nil, webView !== incoming { return }
            // Floor + hard ceiling (mirrors JS). Pathological markup or a
            // residual measure↔frame feedback loop must not grow the card
            // without bound (infinite scroll in the reading pane).
            guard let height = HTMLBodyLayout.measuredHeight(
                fromScriptResult: result) else { return }
            let wasLatched = heightStability.latchedHeight != nil
            let observation = heightStability.observe(height)
            if observation.shouldPublish {
                heightUpdateCount += 1
                if firstHeightMs == nil {
                    firstHeightMs = Int((CFAbsoluteTimeGetCurrent() - renderStart) * 1000)
                }
                let published = observation.height
                let measuredView = webView ?? incoming ?? current
                let measuredWidth = measuredView?.frame.width ?? 0
                if heightCacheAllowed {
                    storeHeight(published, width: measuredWidth)
                } else {
                    pendingCachedHeight = (published, measuredWidth)
                }
                DispatchQueue.main.async { [weak self] in self?.setHeight?(published) }
            }
            if pendingReveal, webView === incoming || (incoming == nil && webView === current) {
                // First positive height is enough to reveal; stability can follow.
                revealIncoming(animated: current != nil && incoming != nil)
            }
            if observation.isStable {
                let latchedNow = heightStability.latchedHeight != nil
                finishRender(reason: !wasLatched && latchedNow
                             ? "oscillation-latched" : "stable")
                notifySettledIfNeeded()
            }
        }

        private func revealIncoming(animated: Bool) {
            guard pendingReveal else { return }
            guard let container else { return }
            let next = incoming ?? current
            guard let next else { return }
            pendingReveal = false

            let previous = (next === incoming) ? current : nil
            if next.superview == nil {
                next.frame = container.bounds
                next.autoresizingMask = [.width, .height]
                container.addSubview(next, positioned: .above, relativeTo: previous)
            }

            let gen = swapGeneration
            let finishSwap = { [weak self] in
                guard let self, self.swapGeneration == gen else { return }
                if let previous, previous !== next {
                    self.recycle(previous, removeFromHierarchy: true)
                }
                next.alphaValue = 1
                self.current = next
                if self.incoming === next {
                    self.incoming = nil
                }
            }

            if animated, previous != nil {
                next.alphaValue = 0
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = HTMLBodyView.swapFadeDuration
                    ctx.allowsImplicitAnimation = true
                    next.animator().alphaValue = 1
                }, completionHandler: finishSwap)
            } else {
                next.alphaValue = 1
                finishSwap()
            }
        }

        private func notifySettledIfNeeded() {
            guard !settledNotified else { return }
            settledNotified = true
            let callback = onSettled
            DispatchQueue.main.async { callback?() }
        }

        private func finishRender(reason: String) {
            renderTimeout?.cancel()
            renderTimeout = nil
            guard let interval = renderInterval else { return }
            renderInterval = nil
            interval.end(extraMeta: "heightUpdates=\(heightUpdateCount) \(reason)"
                         + " measure=\(measuredBy) firstHeightMs=\(firstHeightMs ?? -1)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) {
            guard navigationGate.accepts(navigation) else { return }
            guard webView === incoming || (incoming == nil && webView === current) else { return }
            acceptsHeightReports = false
            // No grace or bound timer may re-enable reports after a failure.
            domReadyGate.reset()
            // Don't leave a blank new view on top of good content.
            if let incoming, incoming === webView, current != nil {
                recycle(incoming, removeFromHierarchy: true)
                self.incoming = nil
                pendingReveal = false
            }
            finishRender(reason: "navigationError")
            pendingCachedHeight = nil
            loadDidEnd()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            guard navigationGate.accepts(navigation) else { return }
            guard webView === incoming || (incoming == nil && webView === current) else { return }
            acceptsHeightReports = false
            domReadyGate.reset()
            if let incoming, incoming === webView, current != nil {
                recycle(incoming, removeFromHierarchy: true)
                self.incoming = nil
                pendingReveal = false
            }
            finishRender(reason: "provisionalError")
            pendingCachedHeight = nil
            loadDidEnd()
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == HTMLBodyLayout.heightHandlerName else { return }
            let webView = message.webView
            if HTMLBodyLayout.isDOMReadyMessage(message.body) {
                if let webView { domReady(in: webView) }
                return
            }
            applyMeasuredHeight(message.body, from: webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url

            // A user clicking a link is handed to the OS (real browser / mail
            // client); we never navigate the message pane itself. A crafted
            // file:// or app-scheme link stays inert. Schemeless hrefs that
            // WebKit resolved against about:blank (baseURL is nil) are
            // recovered to https:// when they look like a real host — see
            // ExternalLinkRecovery.
            if navigationAction.navigationType == .linkActivated {
                if let external = ExternalLinkRecovery.recoveredExternalURL(from: url) {
                    NSWorkspace.shared.open(external)
                }
                decisionHandler(.cancel)
                return
            }

            // Default-deny for everything else. The only navigation an email is
            // allowed to perform is the synthetic initial document load from
            // loadHTMLString (URL is nil or about:blank). This blocks
            // meta-refresh, form submission, JS/redirect, and iframe loads —
            // all of which would otherwise let crafted HTML reach the network
            // (defeating remote-image blocking) or replace the body with a
            // phishing page. Remote images, when opted in, are resource loads,
            // not navigations, so they are unaffected.
            let scheme = url?.scheme?.lowercased()
            if url == nil || scheme == "about" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}
