import SwiftUI
import WebKit

/// A signature as it will be sent, on a white page like Gmail's compose
/// window, in light and dark mode alike: the colours are the sender's, and
/// the HTML that goes out carries no dark-mode colours, so it is shown on
/// the background it was made for.
///
/// No page script, nothing remote (`HTMLBodyCSP` with no image source; the
/// HTML was already rebuilt by `SignatureHTML`, which drops images), no
/// navigation: a click on a link does nothing.
struct SignaturePreview: NSViewRepresentable {
    /// Rebuilt signature HTML (or the rendered Markdown of a local one).
    let html: String
    var maxHeight: CGFloat = 160
    @Binding var height: CGFloat

    static func document(_ html: String) -> String {
        let csp = HTMLBodyCSP.metaTag(allowRemoteImages: false)
            .replacingOccurrences(of: "img-src data: cid:", with: "img-src 'none'")
        let style = "html{margin:0;padding:0;background:#fff}"
            + "body{margin:0;padding:6px 8px;background:#fff;color:#222;"
            + "font:13px Arial,Helvetica,sans-serif}a{color:#1155cc}"
        return "<!doctype html><html><head><meta charset=\"utf-8\">\(csp)"
            + "<meta name=\"color-scheme\" content=\"light\"><style>\(style)</style>"
            + "</head><body>\(html)</body></html>"
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = PreviewWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.setAccessibilityElement(false)
        context.coordinator.load(html, into: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(html, into: view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SignaturePreview
        private var loaded: String?

        init(_ parent: SignaturePreview) { self.parent = parent }

        func load(_ html: String, into view: WKWebView) {
            guard loaded != html else { return }
            loaded = html
            view.loadHTMLString(SignaturePreview.document(html), baseURL: nil)
        }

        /// Only the page DreaMail loads (`loadHTMLString` with no base URL
        /// is about:blank); a click, a drop or anything else is cancelled.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url?.absoluteString ?? ""
            let initial = action.navigationType == .other
                && action.targetFrame?.isMainFrame == true
                && (url.isEmpty || url == "about:blank")
            decisionHandler(initial ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // The body's own height (not the viewport's), so it can shrink.
            webView.evaluateJavaScript("Math.ceil(document.body.getBoundingClientRect().height)") { [weak self] value, _ in
                guard let self, let h = value as? Double else { return }
                let next = min(CGFloat(h), self.parent.maxHeight)
                if abs(next - self.parent.height) > 0.5 { self.parent.height = next }
            }
        }
    }
}

/// A preview box that takes the height of its content (up to a limit).
struct SignaturePreviewBox: View {
    let html: String
    @State private var height: CGFloat = 40

    var body: some View {
        SignaturePreview(html: html, height: $height)
            .frame(height: height)
            .frame(maxWidth: 440, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview as sent")
    }
}

/// The signature in the compose window: shown once, as it is sent, with
/// no label and only a hairline edge (its white page sets it off in dark
/// mode). Read-only; sized to its content up to `maxHeight`, past which it
/// scrolls inside.
struct ComposeSignatureBlock: View {
    let html: String
    /// The signature's text, for VoiceOver: it is not in the editor.
    let text: String
    static let maxHeight: CGFloat = 240
    @State private var height: CGFloat = 40

    var body: some View {
        SignaturePreview(html: html, maxHeight: Self.maxHeight, height: $height)
            .frame(height: height)
            .frame(maxWidth: 480, alignment: .leading)
            .background(Color.white)
            .overlay(Rectangle().strokeBorder(.separator, lineWidth: 0.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Signature")
            .accessibilityValue(text)
            .accessibilityIdentifier("compose.richSignature")
    }
}

/// No context menu: "Open Link" or "Download Linked File" would reach past
/// the preview's no-navigation rule.
///
/// Not a drop target either: a file or link dropped on it is refused (the
/// web view would otherwise try to open it) instead of being taken here.
private final class PreviewWebView: WKWebView {
    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        unregisterDraggedTypes()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        unregisterDraggedTypes()
    }

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
    }
}
