import Foundation

/// What "Print" (the message's "More" menu) prints, as Gmail on the web
/// prints one message: the subject, then the sender with the date, To and
/// Cc, then the body as the pane renders it. Pure — tested;
/// `MessagePrinter` loads the document in an offscreen web view and runs
/// the macOS print panel.
///
/// Every header value is escaped: a subject or sender name holding HTML is
/// printed as text, never interpreted. The body goes through the reading
/// pane's own trusted wrapper (`HTMLBodyDocument.trustedWrapper`), with the
/// CSP the card's remote-content decision gives: printing never loads
/// content the pane blocks.
enum MessagePrint {
    /// The body to print, decided like the pane decides it.
    enum Body: Equatable {
        /// Untrusted message HTML (stored, `cid:`-inlined or with cached
        /// remote images inlined).
        case html(String)
        /// Plain text, escaped when the document is built.
        case text(String)
    }

    /// The pane's body rules, without its collapsed quote (Gmail prints the
    /// whole message): an OpenPGP replacement first (decrypted or signed
    /// text, or its notice: never the armor), then the "Show plain text"
    /// choice, then the HTML body, then the plain text.
    static func body(pgp: PGPBodyDisplay?, showPlainText: Bool,
                     html: String?, text: String) -> Body {
        switch pgp {
        case .text(let shown): return .text(shown)
        case .notice(let notice): return .text(notice.text)
        case .original, nil: break
        }
        if showPlainText, !text.isEmpty { return .text(text) }
        if let html, !html.isEmpty { return .html(html) }
        return .text(text)
    }

    /// Gmail's print date: "Thu, Nov 27, 2025 at 3:04 PM".
    static func dateText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a"
        return formatter.string(from: date)
    }

    /// The header block: escaped text only, inline styles so the message's
    /// own stylesheet cannot easily restyle it.
    static func headerHTML(subject: String, from: String, to: String, cc: String,
                           date: Date, timeZone: TimeZone = .current) -> String {
        let shownSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows = """
        <div style="display:flex;justify-content:space-between;gap:16px;margin:0 0 2px 0">\
        <span>\(escape(from))</span>\
        <span style="white-space:nowrap">\(escape(dateText(date, timeZone: timeZone)))</span></div>
        """
        if !to.isEmpty { rows += "<div>To: \(escape(to))</div>" }
        if !cc.isEmpty { rows += "<div>Cc: \(escape(cc))</div>" }
        return """
        <div id="dreamail-print-header" style="font:13px -apple-system,sans-serif;color:#000;\
        margin:0 0 16px 0;padding:0 0 12px 0;border-bottom:1px solid #ccc">\
        <div style="font-size:18px;font-weight:bold;margin:0 0 12px 0">\
        \(escape(shownSubject.isEmpty ? "(no subject)" : shownSubject))</div>\
        \(rows)</div>
        """
    }

    /// Print stylesheet: always light (paper), the pane's image sizing.
    static let styleCSS = """
    :root { color-scheme: light; }
    body { font: 13px -apple-system, sans-serif; color: #000; background: #fff; margin: 0; }
    img { max-width: 100%; height: auto; }
    """

    /// The whole document handed to the web view.
    static func document(header: String, body: Body, allowRemoteImages: Bool) -> String {
        let content: String
        switch body {
        case .html(let html):
            content = html
        case .text(let text):
            content = "<div style=\"white-space:pre-wrap;font:13px -apple-system,sans-serif\">"
                + escape(text) + "</div>"
        }
        return HTMLBodyDocument.trustedWrapper(
            html: header + content,
            cspMeta: HTMLBodyCSP.metaTag(allowRemoteImages: allowRemoteImages),
            styleCSS: styleCSS)
    }

    private static func escape(_ s: String) -> String {
        ComposeLinks.escapeAttribute(s)
    }
}
