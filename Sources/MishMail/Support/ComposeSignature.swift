import Foundation

/// The signature block of a compose body, and how MishMail inserts,
/// replaces and removes it without touching what the user wrote.
///
/// The compose body is Markdown, so the block is text: a blank line, the
/// standard delimiter line `-- ` (RFC 3676 §4.3, what Gmail and every mail
/// client writes in plain text), then the signature. The plain-text part
/// carries it as is. The HTML part wraps what follows the delimiter in
/// Gmail's own `<div class="gmail_signature">` (`ComposeQuote.authoredHeadHTML`).
/// Drafts, scheduled and offline sends store the body text, so they keep
/// exactly the block the user saw.
enum ComposeSignature {
    /// The line that starts a signature. The trailing space is part of it.
    static let delimiter = "-- "

    /// The block for a signature text; nil for an empty one.
    static func block(for body: String) -> String? {
        let clean = normalizedBody(body)
        guard !clean.isEmpty else { return nil }
        return "\n\n\(delimiter)\n\(clean)"
    }

    /// A signature's text as stored and inserted: Unix newlines, trimmed,
    /// without a leading delimiter (MishMail adds its own), and with no
    /// delimiter line inside, which would split the block in two.
    static func normalizedBody(_ body: String) -> String {
        var lines = body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) == "--" ? "--" : $0 }
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).isEmpty || first == "--" {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The authored text and the signature, split at the last delimiter
    /// line. Nil when there is none.
    static func split(_ text: String) -> (text: String, signature: String)? {
        let lines = text.components(separatedBy: "\n")
        guard let i = lines.lastIndex(of: delimiter) else { return nil }
        return (lines[..<i].joined(separator: "\n"),
                lines[(i + 1)...].joined(separator: "\n"))
    }

    /// The HTML of a signature, Gmail-shaped so Gmail and other clients
    /// recognise it. `innerHTML` comes from the compose renderer.
    static func htmlBlock(innerHTML: String) -> String {
        "<div class=\"gmail_signature\" data-smartmail=\"gmail_signature\">-- <br>\(innerHTML)</div>"
    }

    /// Where `block` sits in `head`, intact: found, with nothing but
    /// whitespace after it (text typed below the delimiter is part of the
    /// signature by convention, so the block counts as edited).
    static func intactRange(of block: String, in head: String) -> Range<String.Index>? {
        guard let range = head.range(of: block, options: .backwards),
              head[range.upperBound...].allSatisfy(\.isWhitespace) else { return nil }
        return range.lowerBound..<head.endIndex
    }

    /// The automatic swap (compose opened, sender changed). Replaces the
    /// block MishMail inserted, `current`, with `new`. Nil, and the body is
    /// left alone, when the user edited or removed that block, or wrote a
    /// signature of their own.
    static func replacingAutomatically(in head: String, current: String?,
                                       with new: String?) -> String? {
        if let current {
            guard let range = intactRange(of: current, in: head) else { return nil }
            return head.replacingCharacters(in: range, with: new ?? "")
        }
        guard split(head) == nil else { return nil }
        return head + (new ?? "")
    }

    /// The user's choice in the compose signature menu: replaces the
    /// inserted block when it is intact, else everything from the last
    /// delimiter line on (the signature by convention, edited), else
    /// appends.
    static func replacingManually(in head: String, current: String?, with new: String?) -> String {
        if let current, let range = intactRange(of: current, in: head) {
            return head.replacingCharacters(in: range, with: new ?? "")
        }
        if let parts = split(head) {
            var before = parts.text
            while before.hasSuffix("\n") { before.removeLast() }
            return before + (new ?? "")
        }
        return head + (new ?? "")
    }

    /// Which of `signatures` ends `head`, for a draft or undone send opened
    /// again: its block can then be swapped like one MishMail just inserted.
    static func detect(in head: String, among signatures: [SignatureRecord])
        -> (signature: SignatureRecord, block: String)? {
        var trimmed = head
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        for signature in signatures {
            if let found = Self.block(for: signature.body), trimmed.hasSuffix(found) {
                return (signature, found)
            }
        }
        return nil
    }
}

/// The signature state of one compose window: the block MishMail last put
/// in the body and which signature it is. Pure, so the swap rules are
/// unit-tested; `ComposeView` holds one and applies the bodies it returns.
struct ComposeSignatureState: Equatable {
    /// The exact text MishMail inserted; nil when it inserted none.
    var block: String?
    /// The signature that block is (nil: "No signature").
    var signatureId: Int64?

    /// The state of a body opened again (draft, undone send): a known
    /// signature at its end counts as inserted, anything else as the user's.
    static func restored(head: String, among signatures: [SignatureRecord]) -> ComposeSignatureState {
        guard let found = ComposeSignature.detect(in: head, among: signatures) else {
            return ComposeSignatureState()
        }
        return ComposeSignatureState(block: found.block, signatureId: found.signature.id)
    }

    /// The sender's default applies (new compose, or From changed). Returns
    /// the new head, or nil to leave the body as it is: nothing changes, or
    /// the user edited the signature (then nothing is asked).
    mutating func applyDefault(_ signature: SignatureRecord?, to head: String) -> String? {
        let wanted = signature.flatMap { ComposeSignature.block(for: $0.body) }
        guard wanted != block else {
            if block != nil { signatureId = signature?.id }
            return nil
        }
        guard let next = ComposeSignature.replacingAutomatically(
            in: head, current: block, with: wanted) else { return nil }
        block = wanted
        signatureId = wanted == nil ? nil : signature?.id
        return next
    }

    /// The user picked a signature (or "No signature") in the menu.
    mutating func choose(_ signature: SignatureRecord?, in head: String) -> String {
        let wanted = signature.flatMap { ComposeSignature.block(for: $0.body) }
        let next = ComposeSignature.replacingManually(in: head, current: block, with: wanted)
        block = wanted
        signatureId = wanted == nil ? nil : signature?.id
        return next
    }
}
