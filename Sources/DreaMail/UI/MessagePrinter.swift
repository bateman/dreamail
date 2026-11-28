import AppKit
import WebKit

/// Runs "Print" for one message: loads `MessagePrint.document` in an
/// offscreen web view set up like the reading pane's (no JavaScript, an
/// ephemeral data store, every navigation but the initial load refused,
/// the remote-image rule while images are blocked), then shows the macOS
/// print panel on the window. Nothing about the message is logged, and the
/// print job is not named after it (job names reach the print system's
/// history).
@MainActor
final class MessagePrinter: NSObject, WKNavigationDelegate {
    /// Printers in flight, kept alive until their print panel closes.
    private static var active: [ObjectIdentifier: MessagePrinter] = [:]
    static let jobTitle = "DreaMail message"

    private let webView: WKWebView
    private weak var window: NSWindow?

    static func print(document: String, allowRemoteImages: Bool, window: NSWindow?) {
        let printer = MessagePrinter(window: window)
        active[ObjectIdentifier(printer)] = printer
        printer.load(document, allowRemoteImages: allowRemoteImages)
    }

    private init(window: NSWindow?) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let info = NSPrintInfo.shared
        let width = max(320, info.paperSize.width - info.leftMargin - info.rightMargin)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 800),
                            configuration: config)
        // Paper is light whatever the app's appearance.
        webView.appearance = NSAppearance(named: .aqua)
        self.window = window
        super.init()
        webView.navigationDelegate = self
    }

    private func load(_ document: String, allowRemoteImages: Bool) {
        let controller = webView.configuration.userContentController
        if allowRemoteImages {
            webView.loadHTMLString(document, baseURL: nil)
        } else if let ready = HTMLRemoteImageBlocker.preparedRuleList {
            controller.add(ready)
            webView.loadHTMLString(document, baseURL: nil)
        } else {
            // Delivered on the main queue. Without the rule the document's
            // own blocked CSP still refuses every remote image.
            HTMLRemoteImageBlocker.ruleList { [weak self] list in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let list { controller.add(list) }
                    self.webView.loadHTMLString(document, baseURL: nil)
                }
            }
        }
    }

    private func finish() {
        webView.navigationDelegate = nil
        Self.active[ObjectIdentifier(self)] = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { return finish() }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.jobTitle = Self.jobTitle
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // A zero-sized print view prints blank pages.
        operation.view?.frame = webView.bounds
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return finish() }
        // `run()` is not supported for a web view's print operation: modal
        // on the window only.
        operation.runModal(for: window, delegate: self,
                           didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                           contextInfo: nil)
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                            contextInfo: UnsafeMutableRawPointer?) {
        finish()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish()
    }

    /// Only the synthetic initial load: no redirect, refresh or link.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        let initial = navigationAction.request.url == nil || scheme == "about"
        decisionHandler(initial && navigationAction.navigationType != .linkActivated ? .allow : .cancel)
    }
}
