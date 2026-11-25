import Foundation

/// The HTML alternative of an outgoing message, from the compose body. Pure:
/// `MailStore` passes the thread and the sender's signatures; tests call it.
enum OutgoingHTML {
    /// The base HTML (`base`), then a Gmail signature the body carries
    /// unchanged gets Gmail's look (`ComposeSignature.withRichSignature`).
    static func build(body: String, forwardOf original: Message?, replyTo replyParent: Message?,
                      draft: Message?, threadMessages: [Message],
                      signatures: [SignatureRecord]) -> String? {
        guard let html = base(body: body, forwardOf: original, replyTo: replyParent,
                              draft: draft, threadMessages: threadMessages) else { return nil }
        let head = String(body[..<(ComposeQuote.quoteStart(in: body) ?? body.endIndex)])
        return ComposeSignature.withRichSignature(html, head: head, signatures: signatures)
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
        if let draft, let html = draft.bodyHTML, !html.isEmpty, body == draft.bodyText {
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
