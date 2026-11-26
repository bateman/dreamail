import Foundation

/// The signature block of a compose body, and how DreaMail inserts,
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
/// The rule throughout: DreaMail only ever cuts text it can show it
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
    /// without a leading delimiter (DreaMail adds its own), and with no
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
    /// made in DreaMail, goes out as rendered text.
    static func withRichSignature(_ html: String, head: String,
                                  signatures: [SignatureRecord]) -> String {
        guard let parts = split(head),
              let match = richSignature(in: head, signatures: signatures),
              let rich = match.html.flatMap({ SignatureHTML.cachedSanitize($0) }) else { return html }
        let text = parts.signature.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = ComposeQuote.signatureBlockHTML(text)
        // Only in the authored head, which every builder writes first: a
        // quoted message may carry the same block (one DreaMail sent).
        // Gmail web writes `class="gmail_quote gmail_quote_container"`.
        let quote = html.range(of: "<div class=\"gmail_quote")?.lowerBound ?? html.endIndex
        guard let range = html.range(of: plain, range: html.startIndex..<quote) else { return html }
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
    /// block DreaMail inserted, `current`, with `new`. Nil, and the body is
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
    /// DreaMail inserted when it is intact, or a stored signature found
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

    /// The user confirmed replacing (or removing) a signature DreaMail did
    /// not insert as is: everything from the last delimiter on goes. Only
    /// behind an explicit choice that says so.
    static func replacingFromDelimiter(in head: String, with new: String?) -> String {
        guard let found = lastDelimiter(in: head) else { return head + (new ?? "") }
        return String(head[..<found.blockStart]) + (new ?? "")
    }

    /// Which of `signatures` ends `head`, for a draft or undone send opened
    /// again: its block can then be swapped like one DreaMail just inserted.
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

/// The signature state of one compose window: the block DreaMail last put
/// in the body, which signature it is and whose. Pure, so the swap rules
/// are unit-tested; `ComposeView` holds one and applies the bodies it returns.
struct ComposeSignatureState: Equatable {
    /// The exact text DreaMail inserted; nil when it inserted none.
    var block: String?
    /// The signature that block is (nil: "No signature").
    var signatureId: Int64?
    /// The account the body's signature belongs to: the one it was written
    /// for. A From change to another account with a block DreaMail cannot
    /// swap asks the user instead of leaving it silently.
    var accountId: String?
    /// A Gmail signature shown as its rendered HTML under the editor, not as
    /// text in the body (`block` is then nil). It goes out as that HTML.
    var richSignatureId: Int64?
    /// A body opened again without a recorded style (a draft from an earlier
    /// build, or made in Gmail): its signature text keeps #79's rule, Gmail's
    /// look while the text is unedited. Cleared once the signature changes.
    var legacy = false

    /// How the signature goes out.
    var style: ComposeSignatureStyle {
        if let richSignatureId { return .rich(richSignatureId) }
        return legacy ? .legacy : .plain
    }

    /// What the menu shows as chosen, from the body as it is now.
    enum Selection: Equatable {
        case none
        case signature(Int64)
        /// A block DreaMail did not insert, or one the user edited.
        case custom
    }

    /// What happened to the body after a sender change.
    enum SenderOutcome: Equatable {
        case replaced(String)
        case unchanged
        /// The body ends with a signature of another account that DreaMail
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

    /// A body opened again with the style it was saved with. `.rich`: the
    /// signature text DreaMail wrote at the end of `head` for the outgoing
    /// copy is taken out again and shown as the rendered block (the head
    /// without it is returned). Anything else, or a rich one whose text is no
    /// longer there word for word, stays text.
    static func restored(head: String, among signatures: [SignatureRecord], accountId: String?,
                         style: ComposeSignatureStyle) -> (state: ComposeSignatureState, head: String) {
        if case .rich(let id) = style,
           let signature = signatures.first(where: { $0.id == id }),
           ComposeSignature.richHTML(of: signature) != nil,
           let found = ComposeSignature.detect(in: head, among: [signature]),
           let range = head.range(of: found.block, options: .backwards) {
            return (ComposeSignatureState(signatureId: id, accountId: accountId, richSignatureId: id),
                    String(head[..<range.lowerBound]))
        }
        var state = restored(head: head, among: signatures, accountId: accountId)
        state.legacy = style == .legacy
        return (state, head)
    }

    func selection(in head: String) -> Selection {
        if let richSignatureId { return .signature(richSignatureId) }
        if let block, ComposeSignature.intactRange(of: block, in: head) != nil {
            return signatureId.map { .signature($0) } ?? .custom
        }
        return ComposeSignature.lastDelimiter(in: head) == nil ? .none : .custom
    }

    /// The sender changed (or compose opened): its default applies when
    /// DreaMail can swap without touching the user's text. A block it
    /// cannot swap stays, silently within one account, with a decision
    /// asked when the sender is another account.
    mutating func senderChanged(to signature: SignatureRecord?, accountId newAccount: String,
                                head: String) -> SenderOutcome {
        let richId = ComposeSignature.richId(of: signature)
        let wanted = richId == nil ? signature.flatMap { ComposeSignature.block(for: $0.body) } : nil
        if richSignatureId != nil {
            // The rendered block is DreaMail's and cannot be edited: it
            // always swaps. A text signature is added only where the body
            // has none of the user's own.
            accountId = newAccount
            legacy = false
            richSignatureId = richId
            signatureId = richId
            block = nil
            guard let wanted, ComposeSignature.lastDelimiter(in: head) == nil else { return .unchanged }
            block = wanted
            signatureId = signature?.id
            return .replaced(head + wanted)
        }
        let sameAccount = accountId.map {
            $0.caseInsensitiveCompare(newAccount) == .orderedSame
        } ?? true
        let hasDelimiter = ComposeSignature.lastDelimiter(in: head) != nil
        let intact = block.map { ComposeSignature.intactRange(of: $0, in: head) != nil } ?? false
        if wanted == block, intact || (block == nil && !hasDelimiter) {
            if block != nil { signatureId = signature?.id }
            if let richId {
                richSignatureId = richId
                signatureId = richId
                legacy = false
            }
            accountId = newAccount
            return .unchanged
        }
        if let next = ComposeSignature.replacingAutomatically(in: head, current: block, with: wanted) {
            block = wanted
            signatureId = richId ?? (wanted == nil ? nil : signature?.id)
            richSignatureId = richId
            legacy = false
            accountId = newAccount
            return .replaced(next)
        }
        // Nothing DreaMail can swap. With no block left (the user removed
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
        let richId = ComposeSignature.richId(of: signature)
        let wanted = richId == nil ? signature.flatMap { ComposeSignature.block(for: $0.body) } : nil
        // A rendered block is not in the text: nothing to cut.
        let next = richSignatureId != nil
            ? head + (wanted ?? "")
            : ComposeSignature.replacingManually(in: head, current: block, with: wanted,
                                                 known: known)
        block = wanted
        signatureId = richId ?? (wanted == nil ? nil : signature?.id)
        richSignatureId = richId
        legacy = false
        if let owner = signature?.accountId { accountId = owner }
        return next
    }

    /// "Edit signature as text": the rendered block becomes its text at the
    /// end of `head`, which then goes out as typed. Nil when no block is shown.
    mutating func editAsText(_ signature: SignatureRecord?, in head: String) -> String? {
        guard richSignatureId != nil, let signature, signature.id == richSignatureId,
              let wanted = ComposeSignature.block(for: signature.body) else { return nil }
        richSignatureId = nil
        legacy = false
        block = wanted
        signatureId = signature.id
        return head + wanted
    }

    /// The user answered `.needsDecision`: replace with (or remove for nil)
    /// the new sender's default, cutting the old block from its delimiter.
    mutating func resolveReplacing(with signature: SignatureRecord?, accountId newAccount: String,
                                   head: String) -> String {
        let richId = ComposeSignature.richId(of: signature)
        let wanted = richId == nil ? signature.flatMap { ComposeSignature.block(for: $0.body) } : nil
        block = wanted
        signatureId = richId ?? (wanted == nil ? nil : signature?.id)
        richSignatureId = richId
        legacy = false
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
    enum Row: Equatable {
        case manage
        case divider
        case none(checked: Bool)
        case signature(id: Int64, name: String, checked: Bool)
        /// "Edit signature as text", while a rendered signature is shown.
        case editAsText
    }

    static func rows(signatures: [SignatureRecord],
                     selection: ComposeSignatureState.Selection,
                     richShown: Bool = false) -> [Row] {
        var rows: [Row] = [.manage, .divider, .none(checked: selection == .none)]
        for signature in signatures {
            guard let id = signature.id else { continue }
            rows.append(.signature(id: id, name: signature.name,
                                   checked: selection == .signature(id)))
        }
        if richShown { rows += [.divider, .editAsText] }
        return rows
    }
}

/// A From change to another account left a signature DreaMail cannot swap:
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

/// How a compose body's signature goes out, kept beside the body wherever
/// the body is kept (undo send, scheduled and offline sends, the Outbox, the
/// Gmail draft), so a body opened again shows the signature as it was.
enum ComposeSignatureStyle: Equatable, Hashable {
    /// Opened again with no style recorded (an earlier build, Gmail web):
    /// #79's rule, Gmail's look while the signature text is unedited.
    case legacy
    /// As typed: the text in the body is what goes out.
    case plain
    /// The Gmail signature with this id, shown and sent as its HTML. The
    /// body handed to the send path carries its text block, for text/plain.
    case rich(Int64)

    /// The value stored in `scheduledSend` and `localDraft` (v68); nil is legacy.
    var storageValue: String? {
        switch self {
        case .legacy: return nil
        case .plain: return "plain"
        case .rich(let id): return "rich:\(id)"
        }
    }

    init(storageValue: String?) {
        guard let value = storageValue else { self = .legacy; return }
        if value == "plain" { self = .plain; return }
        if value.hasPrefix("rich:"), let id = Int64(value.dropFirst("rich:".count)), id > 0 {
            self = .rich(id)
            return
        }
        self = .legacy
    }

    var richSignatureId: Int64? {
        if case .rich(let id) = self { return id }
        return nil
    }
}

extension ComposeSignature {
    /// The rebuilt HTML of a signature that keeps Gmail's look; nil for one
    /// made or edited here, or one the sanitiser refuses.
    static func richHTML(of signature: SignatureRecord?) -> String? {
        signature?.html.flatMap { SignatureHTML.cachedSanitize($0) }?.html
    }

    /// The id of a signature compose shows rendered; nil for a text one.
    static func richId(of signature: SignatureRecord?) -> Int64? {
        guard let id = signature?.id, richHTML(of: signature) != nil else { return nil }
        return id
    }

    /// The body handed to the send path for a rendered signature: its text
    /// block goes where it would sit in the editor, at the end of the
    /// authored head, before any quote. The editor never holds it.
    /// The separator before the quote stays as it was (the quote matchers
    /// compare the end of the body); trailing blank lines of the head go,
    /// as they would above a block in the editor.
    static func assembled(body: String, signature: SignatureRecord) -> String {
        guard let block = block(for: signature.body) else { return body }
        let quote = ComposeQuote.quoteStart(in: body)
        var cut = quote ?? body.endIndex
        while cut > body.startIndex, body[body.index(before: cut)].isWhitespace {
            cut = body.index(before: cut)
        }
        let tail = quote == nil ? "" : String(body[cut...])
        return String(body[..<cut]) + block + tail
    }

    /// The outgoing HTML with `signature`'s look in the authored head: the
    /// block `authoredHeadHTML` wrote for its text is swapped for its HTML.
    /// The choice is the compose state's, not a text match; the text after
    /// the last delimiter is still checked to be that signature's, so the
    /// swap can never replace other text. Unchanged when it is not there.
    static func withRichSignature(_ html: String, head: String,
                                  signature: SignatureRecord) -> String {
        guard let parts = split(head), let rich = richHTML(of: signature) else { return html }
        let text = parts.signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, normalizedBody(signature.body) == text else { return html }
        let plain = ComposeQuote.signatureBlockHTML(text)
        let quote = html.range(of: "<div class=\"gmail_quote")?.lowerBound ?? html.endIndex
        guard let range = html.range(of: plain, range: html.startIndex..<quote) else { return html }
        return html.replacingCharacters(in: range, with: htmlBlock(innerHTML: rich))
    }

    // MARK: - The style in a Gmail draft

    /// The attribute a saved draft's signature block carries so that the
    /// draft, opened again, shows its signature the same way. Drafts only:
    /// a sent message never carries it.
    static let styleAttribute = "data-dreamail-signature"

    private static let blockOpening = "<div class=\"gmail_signature\" data-smartmail=\"gmail_signature\""

    /// `html` with `style` recorded on the signature block of its authored
    /// head. Unchanged without such a block, or for `.legacy`.
    static func markingStyle(_ style: ComposeSignatureStyle, in html: String) -> String {
        guard let value = style.storageValue else { return html }
        let quote = html.range(of: "<div class=\"gmail_quote")?.lowerBound ?? html.endIndex
        guard let range = html.range(of: blockOpening, range: html.startIndex..<quote) else { return html }
        return html.replacingCharacters(in: range, with: blockOpening + " \(styleAttribute)=\"\(value)\"")
    }

    /// The style a saved draft recorded, read from its authored head only (a
    /// quoted message cannot set it); nil when it has none.
    static func markedStyle(in html: String?) -> ComposeSignatureStyle? {
        guard let html else { return nil }
        let quote = html.range(of: "<div class=\"gmail_quote")?.lowerBound ?? html.endIndex
        let prefix = blockOpening + " \(styleAttribute)=\""
        guard let start = html.range(of: prefix, range: html.startIndex..<quote)?.upperBound,
              let end = html[start..<quote].firstIndex(of: "\"") else { return nil }
        let value = String(html[start..<end])
        guard value.count <= 32 else { return nil }
        let style = ComposeSignatureStyle(storageValue: value)
        return style == .legacy ? nil : style
    }
}
