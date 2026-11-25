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
        """
        <!doctype html><html><head><meta charset="utf-8">
        \(HTMLBodyCSP.metaTag(allowRemoteImages: false).replacingOccurrences(
            of: "img-src data: cid:", with: "img-src 'none'"))
        <meta name="color-scheme" content="light">
        <style>html{margin:0;padding:0;background:#fff}body{margin:0;padding:6px 8px;\
        background:#fff;color:#222;font:13px Arial,Helvetica,sans-serif}a{color:#1155cc}</style>
        </head><body>\(html)</body></html>
        """
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
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

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .other ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] value, _ in
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
