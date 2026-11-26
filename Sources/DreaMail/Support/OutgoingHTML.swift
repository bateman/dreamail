import Foundation

/// The HTML alternative of an outgoing message, from the compose body. Pure:
/// `MailStore` passes the thread and the sender's signatures; tests call it.
enum OutgoingHTML {
    /// The base HTML (`base`), then the signature's look by `style`: a
    /// rendered Gmail signature (`.rich`) gets its HTML in the authored
    /// head; `.legacy` keeps #79's rule (a Gmail signature the body carries
    /// unchanged gets Gmail's look); `.plain` goes out as typed. For a draft
    /// (`marksDraft`) the style is recorded on the signature block so the
    /// draft opens again the same way; a sent message never carries it.
    static func build(body: String, forwardOf original: Message?, replyTo replyParent: Message?,
                      draft: Message?, threadMessages: [Message],
                      signatures: [SignatureRecord],
                      style: ComposeSignatureStyle = .legacy,
                      marksDraft: Bool = false) -> String? {
        // A draft DreaMail saved with another style is rebuilt from the body:
        // its HTML carries the look of the style it was saved with. With the
        // same style it is reused (a reopened forward has no original to
        // rebuild the forwarded HTML from).
        let reusable = draft.flatMap { draft -> Message? in
            guard let marked = ComposeSignature.markedStyle(in: draft.bodyHTML) else { return draft }
            return marked == style ? draft : nil
        }
        guard let html = base(body: body, forwardOf: original, replyTo: replyParent,
                              draft: reusable, threadMessages: threadMessages) else { return nil }
        let head = String(body[..<(ComposeQuote.quoteStart(in: body) ?? body.endIndex)])
        let styled: String
        switch style {
        case .legacy:
            styled = ComposeSignature.withRichSignature(html, head: head, signatures: signatures)
        case .plain:
            styled = html
        case .rich(let id):
            styled = signatures.first(where: { $0.id == id }).map {
                ComposeSignature.withRichSignature(html, head: head, signature: $0)
            } ?? html
        }
        // Never on a send, wherever an editor left it; a draft is marked afresh.
        let clean = ComposeSignature.strippingStyle(styled)
        return marksDraft ? ComposeSignature.markingStyle(style, in: clean) : clean
    }

    /// The same text but for spaces at line ends: Gmail may hand a draft's
    /// text part back with the space of the `-- ` line trimmed.
    static func sameText(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        func lines(_ s: String) -> [Substring] {
            s.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                var line = line
                while line.last == " " || line.last == "\t" { line = line.dropLast() }
                return line
            }
        }
        return lines(a) == lines(b)
    }

    static func base(body: String, forwardOf original: Message?,
                     replyTo replyParent: Message?, draft: Message?,
                     threadMessages threadMsgs: [Message]) -> String? {
        if let orig = original {
            if let match = ForwardComposer.matchHTMLUpgrade(
                body: body, original: orig, threadMessages: threadMsgs) {
                return ForwardComposer.htmlBody(userText: match.userText, parts: match.parts)
            }
            // Content drift (new mail in thread since compose) or an edited
            // quote: neither package matches → fall through to plain/markdown.
        }
        if let parent = replyParent,
           let match = ReplyComposer.matchHTMLUpgrade(body: body, original: parent) {
            return ReplyComposer.htmlBody(userText: match.userText, original: match.original)
        }
        if let draft, let html = draft.bodyHTML, !html.isEmpty,
           sameText(body, draft.bodyText) {
            return html
        }
        // A signature with no quote after it (new mail, or a quote the user
        // removed): authored text plus Gmail's signature block.
        if ComposeSignature.split(body) != nil, ComposeQuote.quoteStart(in: body) == nil {
            return ComposeQuote.authoredHeadHTML(body)
        }
        // Markdown-authored body. Reply quotes that failed the upgrade above
        // still match `^>\s` here — best-effort, not Gmail-shaped.
        if Markdown.looksLikeMarkdown(body) {
            return Markdown.toHTML(body)
        }
        // Plain prose: still emit HTML when there are links to click.
        let fragment = ComposeLinks.htmlFragment(from: body)
        return fragment.isEmpty ? nil : fragment
    }
}
