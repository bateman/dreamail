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
///
/// The rule throughout: MishMail only ever cuts text it can show it
/// inserted (the block it put there, intact, or a stored signature
/// verbatim). Anything else stays; at most a block is added.
enum ComposeSignature {
    /// The line that starts a signature. The trailing space is part of it.
    static let delimiter = "-- "

    /// A delimiter line. `--` without the space counts too: a draft that
    /// went through Gmail can come back with the space trimmed.
    static func isDelimiter<S: StringProtocol>(_ line: S) -> Bool {
        line == "-- " || line == "--"
    }

    /// Stands in for a delimiter line inside a signature, which would
    /// otherwise split the block in two.
    static let innerDelimiterReplacement = "—"

    /// The block for a signature text; nil for an empty one.
    static func block(for body: String) -> String? {
        let clean = normalizedBody(body)
        guard !clean.isEmpty else { return nil }
        return "\n\n\(delimiter)\n\(clean)"
    }

    /// A signature's text as stored and inserted: Unix newlines, trimmed,
    /// without a leading delimiter (MishMail adds its own), and with no
    /// delimiter line inside.
    static func normalizedBody(_ body: String) -> String {
        var lines = body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        while let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first.isEmpty || first == "--" {
            lines.removeFirst()
        }
        lines = lines.map {
            $0.trimmingCharacters(in: .whitespaces) == "--" ? innerDelimiterReplacement : $0
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why a signature cannot be saved, or nil. Checked on the normalised
    /// text: empty, over the limit (refused, never cut mid-link), or with a
    /// line compose would take for the start of quoted mail.
    static func saveProblem(_ body: String, maxLength: Int) -> String? {
        let clean = normalizedBody(body)
        if clean.isEmpty { return "Write the signature first." }
        if clean.count > maxLength {
            return "A signature can hold up to \(maxLength.formatted()) characters; this one has \(clean.count.formatted())."
        }
        if ComposeQuote.quoteStart(in: "\n" + clean + "\n") != nil {
            return "A line like “On … wrote:” or “Forwarded message” would be taken for quoted mail. Change that line."
        }
        return nil
    }

    // MARK: - Finding the block

    /// The last delimiter line of `text`: where the block starts (the blank
    /// lines before the delimiter included, at most two) and where the
    /// signature text after the delimiter starts. Nil when there is none.
    static func lastDelimiter(in text: String)
        -> (blockStart: String.Index, signatureStart: String.Index)? {
        var lineStart = text.startIndex
        var found: (String.Index, String.Index)?
        while lineStart <= text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            if isDelimiter(text[lineStart..<lineEnd]) {
                var blockStart = lineStart
                for _ in 0..<2 {
                    guard blockStart > text.startIndex else { break }
                    let before = text.index(before: blockStart)
                    guard text[before] == "\n" else { break }
                    blockStart = before
                }
                let signatureStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
                found = (blockStart, signatureStart)
            }
            guard lineEnd < text.endIndex else { break }
            lineStart = text.index(after: lineEnd)
        }
        return found
    }

    /// The authored text and the signature, split at the last delimiter
    /// line. Nil when there is none.
    static func split(_ text: String) -> (text: String, signature: String)? {
        let lines = text.components(separatedBy: "\n")
        guard let i = lines.lastIndex(where: { isDelimiter($0) }) else { return nil }
        return (lines[..<i].joined(separator: "\n"),
                lines[(i + 1)...].joined(separator: "\n"))
    }

    /// The HTML of a signature, Gmail-shaped so Gmail and other clients
    /// recognise it. `innerHTML` comes from the compose renderer.
    static func htmlBlock(innerHTML: String) -> String {
        "<div class=\"gmail_signature\" data-smartmail=\"gmail_signature\">-- <br>\(innerHTML)</div>"
    }

    /// The outgoing HTML with Gmail's look for the signature: when the text
    /// after the last delimiter of `head` is, word for word, a signature
    /// that kept Gmail's HTML, its rendered block is swapped for that HTML
    /// (rebuilt again by `SignatureHTML`). A signature edited in compose, or
    /// made in MishMail, goes out as rendered text.
    static func withRichSignature(_ html: String, head: String,
                                  signatures: [SignatureRecord]) -> String {
        guard let parts = split(head),
              let match = richSignature(in: head, signatures: signatures),
              let rich = match.html.flatMap({ SignatureHTML.sanitize($0) }) else { return html }
        let text = parts.signature.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = ComposeQuote.signatureBlockHTML(text)
        guard let range = html.range(of: plain, options: .backwards) else { return html }
        return html.replacingCharacters(in: range, with: htmlBlock(innerHTML: rich.html))
    }

    /// The Gmail copy whose look a body sends: the signature after the last
    /// delimiter of `head`, word for word, that kept Gmail's HTML. Nil when
    /// the user changed it (it then goes out as typed) or it is not one.
    static func richSignature(in head: String, signatures: [SignatureRecord]) -> SignatureRecord? {
        guard let parts = split(head) else { return nil }
        let text = parts.signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return signatures.first { $0.html != nil && normalizedBody($0.body) == text }
    }

    /// Where `block` sits in `head`, intact: found, with nothing but
    /// whitespace after it (text typed below the delimiter is part of the
    /// signature by convention, so the block counts as edited).
    static func intactRange(of block: String, in head: String) -> Range<String.Index>? {
        guard let range = head.range(of: block, options: .backwards),
              head[range.upperBound...].allSatisfy(\.isWhitespace) else { return nil }
        return range.lowerBound..<head.endIndex
    }

    /// The last delimiter followed by one of `known` signature texts word
    /// for word, at a line end: the range of that block (delimiter, blank
    /// lines before it and the known text). What follows (a P.S.) is not
    /// in the range.
    static func knownBlockRange(in head: String, known: [String]) -> Range<String.Index>? {
        guard let found = lastDelimiter(in: head) else { return nil }
        let after = head[found.signatureStart...]
        for text in known.map(normalizedBody).filter({ !$0.isEmpty })
            .sorted(by: { $0.count > $1.count }) where after.hasPrefix(text) {
            let end = head.index(found.signatureStart, offsetBy: text.count)
            if end == head.endIndex || head[end] == "\n" {
                return found.blockStart..<end
            }
        }
        return nil
    }

    // MARK: - Changing the block

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
        guard lastDelimiter(in: head) == nil else { return nil }
        return head + (new ?? "")
    }

    /// The user's choice in the compose signature menu. Replaces the block
    /// MishMail inserted when it is intact, or a stored signature found
    /// word for word after the last delimiter (text after it stays).
    /// Otherwise nothing is cut: the new block is added at the end.
    static func replacingManually(in head: String, current: String?, with new: String?,
                                  known: [String]) -> String {
        if let current, let range = intactRange(of: current, in: head) {
            return head.replacingCharacters(in: range, with: new ?? "")
        }
        if current != nil, let range = knownBlockRange(in: head, known: known) {
            return head.replacingCharacters(in: range, with: new ?? "")
        }
        return head + (new ?? "")
    }

    /// The user confirmed replacing (or removing) a signature MishMail did
    /// not insert as is: everything from the last delimiter on goes. Only
    /// behind an explicit choice that says so.
    static func replacingFromDelimiter(in head: String, with new: String?) -> String {
        guard let found = lastDelimiter(in: head) else { return head + (new ?? "") }
        return String(head[..<found.blockStart]) + (new ?? "")
    }

    /// Which of `signatures` ends `head`, for a draft or undone send opened
    /// again: its block can then be swapped like one MishMail just inserted.
    /// The delimiter may have lost its trailing space.
    static func detect(in head: String, among signatures: [SignatureRecord])
        -> (signature: SignatureRecord, block: String)? {
        guard let found = lastDelimiter(in: head) else { return nil }
        var end = head.endIndex
        while end > found.signatureStart, head[head.index(before: end)].isWhitespace {
            end = head.index(before: end)
        }
        let text = String(head[found.signatureStart..<end])
        guard let signature = signatures.first(where: {
            let body = normalizedBody($0.body)
            return !body.isEmpty && body == text
        }) else { return nil }
        return (signature, String(head[found.blockStart..<end]))
    }
}

/// The signature state of one compose window: the block MishMail last put
/// in the body, which signature it is and whose. Pure, so the swap rules
/// are unit-tested; `ComposeView` holds one and applies the bodies it returns.
struct ComposeSignatureState: Equatable {
    /// The exact text MishMail inserted; nil when it inserted none.
    var block: String?
    /// The signature that block is (nil: "No signature").
    var signatureId: Int64?
    /// The account the body's signature belongs to: the one it was written
    /// for. A From change to another account with a block MishMail cannot
    /// swap asks the user instead of leaving it silently.
    var accountId: String?

    /// What the menu shows as chosen, from the body as it is now.
    enum Selection: Equatable {
        case none
        case signature(Int64)
        /// A block MishMail did not insert, or one the user edited.
        case custom
    }

    /// What happened to the body after a sender change.
    enum SenderOutcome: Equatable {
        case replaced(String)
        case unchanged
        /// The body ends with a signature of another account that MishMail
        /// cannot swap: the user decides (replace, remove, keep).
        case needsDecision
    }

    /// The state of a body opened again (draft, undone send): a known
    /// signature at its end counts as inserted, anything else as the user's.
    static func restored(head: String, among signatures: [SignatureRecord],
                         accountId: String?) -> ComposeSignatureState {
        guard let found = ComposeSignature.detect(in: head, among: signatures) else {
            return ComposeSignatureState(accountId: accountId)
        }
        return ComposeSignatureState(block: found.block, signatureId: found.signature.id,
                                     accountId: accountId)
    }

    func selection(in head: String) -> Selection {
        if let block, ComposeSignature.intactRange(of: block, in: head) != nil {
            return signatureId.map { .signature($0) } ?? .custom
        }
        return ComposeSignature.lastDelimiter(in: head) == nil ? .none : .custom
    }

    /// The sender changed (or compose opened): its default applies when
    /// MishMail can swap without touching the user's text. A block it
    /// cannot swap stays, silently within one account, with a decision
    /// asked when the sender is another account.
    mutating func senderChanged(to signature: SignatureRecord?, accountId newAccount: String,
                                head: String) -> SenderOutcome {
        let wanted = signature.flatMap { ComposeSignature.block(for: $0.body) }
        let sameAccount = accountId.map {
            $0.caseInsensitiveCompare(newAccount) == .orderedSame
        } ?? true
        let hasDelimiter = ComposeSignature.lastDelimiter(in: head) != nil
        let intact = block.map { ComposeSignature.intactRange(of: $0, in: head) != nil } ?? false
        if wanted == block, intact || (block == nil && !hasDelimiter) {
            if block != nil { signatureId = signature?.id }
            accountId = newAccount
            return .unchanged
        }
        if let next = ComposeSignature.replacingAutomatically(in: head, current: block, with: wanted) {
            block = wanted
            signatureId = wanted == nil ? nil : signature?.id
            accountId = newAccount
            return .replaced(next)
        }
        // Nothing MishMail can swap. With no block left (the user removed
        // it) or within one account, the body stays as the user made it.
        guard hasDelimiter, !sameAccount else {
            if !hasDelimiter { accountId = newAccount }
            return .unchanged
        }
        return .needsDecision
    }

    /// The user picked a signature (or "No signature") in the menu.
    /// `known` is the text of the account's stored signatures.
    mutating func choose(_ signature: SignatureRecord?, in head: String,
                         known: [String] = []) -> String {
        let wanted = signature.flatMap { ComposeSignature.block(for: $0.body) }
        let next = ComposeSignature.replacingManually(in: head, current: block, with: wanted,
                                                      known: known)
        block = wanted
        signatureId = wanted == nil ? nil : signature?.id
        if let owner = signature?.accountId { accountId = owner }
        return next
    }

    /// The user answered `.needsDecision`: replace with (or remove for nil)
    /// the new sender's default, cutting the old block from its delimiter.
    mutating func resolveReplacing(with signature: SignatureRecord?, accountId newAccount: String,
                                   head: String) -> String {
        let wanted = signature.flatMap { ComposeSignature.block(for: $0.body) }
        block = wanted
        signatureId = wanted == nil ? nil : signature?.id
        accountId = newAccount
        return ComposeSignature.replacingFromDelimiter(in: head, with: wanted)
    }

    /// The user answered `.needsDecision` with Keep.
    mutating func resolveKeeping(accountId newAccount: String) {
        accountId = newAccount
    }
}

/// The compose signature menu, as in Gmail: "Manage signatures", a
/// separator, "No signature", then each signature of the sending account
/// by name. The check mark follows the body (`ComposeSignatureState.selection`):
/// none on a signature the user typed or edited.
enum ComposeSignatureMenu {
    enum Row: Equatable, Identifiable {
        case manage
        case divider
        case none(checked: Bool)
        case signature(id: Int64, name: String, checked: Bool)

        var id: String {
            switch self {
            case .manage: return "manage"
            case .divider: return "divider"
            case .none: return "none"
            case .signature(let id, _, _): return "signature.\(id)"
            }
        }
    }

    static func rows(signatures: [SignatureRecord],
                     selection: ComposeSignatureState.Selection) -> [Row] {
        var rows: [Row] = [.manage, .divider, .none(checked: selection == .none)]
        for signature in signatures {
            guard let id = signature.id else { continue }
            rows.append(.signature(id: id, name: signature.name,
                                   checked: selection == .signature(id)))
        }
        return rows
    }
}

/// A From change to another account left a signature MishMail cannot swap:
/// the compose window asks whether to replace it with `signature` (remove
/// it, for nil) or keep it.
struct SignatureConflict: Equatable {
    let accountId: String
    let signature: SignatureRecord?
}

extension ComposeSignature {
    /// The text the user wrote above the signature: what "Save as snippet"
    /// keeps (no quote, no signature block).
    static func authoredText(ofHead head: String) -> String {
        var text = head
        if let found = lastDelimiter(in: head) { text = String(head[..<found.blockStart]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Whether a compose body is still its prefill (no draft saved, no discard
/// prompt), kept true across the quote's expand and collapse when the head
/// is untouched (empty, or just the automatic signature).
enum ComposePrefillBaseline {
    static func isUntouched(body: String, initial: String) -> Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
            == initial.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The baseline once the collapsed quote is inlined into `expanded`.
    static func afterExpand(head: String, initial: String, quotedTail: String,
                            expanded: String) -> String {
        isUntouched(body: head, initial: initial) ? expanded : "\n\n" + quotedTail
    }

    /// The baseline once the quote is collapsed again, leaving `head`.
    static func afterCollapse(body: String, initial: String, head: String) -> String {
        isUntouched(body: body, initial: initial) ? head : initial
    }
}

extension SignatureUse {
    /// For a draft opened again: threaded, or carrying a forwarded block,
    /// it is a reply or forward.
    static func forDraft(referencesHeader: String, body: String) -> SignatureUse {
        referencesHeader.isEmpty && !body.contains(ForwardComposer.marker) ? .newMessage : .reply
    }
}
