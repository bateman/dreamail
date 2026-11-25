import Foundation
import GRDB

// Creating, editing and deleting Gmail filters from Settings → Gmail filters,
// modelled on Gmail Web (Settings ▸ Filters and Blocked Addresses). Nothing
// here is persisted: the filter list is an in-memory cache of the server's,
// dropped with the account (DEC-019). Criteria never reach a log line.

// MARK: - Errors

/// What a failed filter change tells the user. Gmail's own message is shown
/// in the sheet only; `DiagnosticLog` records the HTTP category, never this.
indirect enum GmailFilterError: LocalizedError, Equatable {
    /// 403 without a quota reason: the sign-in predates gmail.settings.basic.
    case missingScope
    /// 429, or 403 with a rate-limit reason.
    case quota
    /// 400: Gmail refused the criteria or actions. Carries Gmail's message.
    case invalid(String)
    case other(String)
    /// Forwarding needs gmail.settings.sharing, which MishMail does not ask for.
    case forwardingNotSupported
    /// An edit created the new filter but could not delete the original:
    /// both are now on the server.
    case oldFilterKept(created: GFilter, cause: GmailFilterError)

    init(_ error: Error) {
        if let own = error as? GmailFilterError {
            self = own
            return
        }
        guard case GmailError.http(let code, let body) = error else {
            self = .other(error.localizedDescription)
            return
        }
        switch code {
        case 429:
            self = .quota
        case 403 where MessageFetchFailureKind.isRateLimitBody(body):
            self = .quota
        case 403:
            self = .missingScope
        case 400:
            self = .invalid(Self.gmailMessage(body) ?? "")
        default:
            self = .other(error.localizedDescription)
        }
    }

    /// The request may have reached Gmail and been applied: a transport
    /// failure (timeout, lost connection) or a 5xx. The cache cannot know,
    /// so the caller re-reads the list.
    static func outcomeUnknown(_ error: Error) -> Bool {
        if case GmailFilterError.oldFilterKept = error { return true }
        if error is GmailFilterError || error is CancellationError { return false }
        guard case GmailError.http(let code, _) = error else {
            return !(error is GmailError)
        }
        return code >= 500 || code == 0
    }

    var errorDescription: String? {
        switch self {
        case .missingScope:
            return "MishMail doesn't have permission to manage this account's filters yet. Sign in to it again with Add Google Account… (Accounts pane) to grant it; the account and its mail stay as they are."
        case .quota:
            return "Gmail is limiting requests for this account right now. Wait a minute and try again."
        case .invalid(let message):
            return message.isEmpty
                ? "Gmail didn't accept this filter. Check the criteria and actions."
                : "Gmail didn't accept this filter: \(message)"
        case .other(let message):
            return message
        case .forwardingNotSupported:
            return "Filters that forward mail can only be created or edited in Gmail."
        case .oldFilterKept(_, let cause):
            return "The edited filter was saved, but the original couldn't be removed (\(cause.errorDescription ?? "unknown error")). Both are in place now: delete the old one."
        }
    }

    /// `error.message` from a Google error body, flattened and capped.
    static func gmailMessage(_ body: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let err = object["error"] as? [String: Any],
              let message = err["message"] as? String else { return nil }
        let flat = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return flat.count > 200 ? String(flat.prefix(200)) + "…" : flat
    }
}

// MARK: - Cache

/// Per-account filters as last read from Gmail, plus the load error shown
/// in Settings. In memory only.
struct GmailFilterCache: Equatable {
    /// Nil entry: not loaded yet. Empty: loaded, the account has none.
    private(set) var filters: [String: [GFilter]] = [:]
    var loadErrors: [String: String] = [:]
    /// Bumped by every edit, so a list read that started before an edit
    /// cannot overwrite the edit's result when it lands after it.
    private(set) var revisions: [String: Int] = [:]

    /// A change Gmail confirmed.
    enum Edit: Equatable {
        case created(GFilter)
        case replaced(oldId: String, with: GFilter)
        case deleted(id: String)
    }

    func revision(_ account: String) -> Int { revisions[account] ?? 0 }

    /// A list read from Gmail. Dropped when an edit landed since `revision`.
    mutating func loaded(_ list: [GFilter], account: String, revision: Int) {
        guard self.revision(account) == revision else { return }
        filters[account] = list
        loadErrors[account] = nil
    }

    /// Leaves the slot empty (so Settings shows the error) unless a good
    /// list is already cached.
    mutating func loadFailed(_ message: String, account: String) {
        loadErrors[account] = message
    }

    mutating func setDemo(account: String) {
        filters[account] = []
        loadErrors[account] = nil
    }

    /// Applies only to an account whose list is loaded: a removed account
    /// (forgotten) or one never read gets nothing back.
    mutating func apply(_ edit: Edit, account: String) {
        guard var list = filters[account] else { return }
        switch edit {
        case .created(let filter):
            list.removeAll { $0.id == filter.id }
            list.append(filter)
        case .replaced(let oldId, let filter):
            if list.contains(where: { $0.id == oldId }) {
                // The new filter takes the old one's place in the list.
                list = list.filter { $0.id != filter.id }
                    .map { $0.id == oldId ? filter : $0 }
            } else {
                list.removeAll { $0.id == filter.id }
                list.append(filter)
            }
        case .deleted(let id):
            list.removeAll { $0.id == id }
        }
        filters[account] = list
        revisions[account, default: 0] += 1
    }

    /// What a failed edit still changed on Gmail.
    mutating func apply(failure: GmailFilterError, account: String) {
        if case .oldFilterKept(let created, _) = failure {
            apply(.created(created), account: account)
        }
    }

    /// DEC-019: nothing of a removed account stays in memory.
    mutating func forget(account: String) {
        filters[account] = nil
        loadErrors[account] = nil
        revisions[account] = nil
    }
}

// MARK: - Editor model

/// The editor's fields, laid out like Gmail Web's filter dialog. Built from
/// an existing filter, it keeps the actions the dialog has no control for
/// (extra labels, other system labels) and excludeChats; the sheet lists
/// them read-only and can drop them. Forwarding is never sent.
struct GmailFilterDraft: Equatable {
    enum SizeComparison: String, CaseIterable { case larger, smaller }
    enum SizeUnit: Int, CaseIterable {
        case mb = 1_048_576, kb = 1_024, bytes = 1
        var title: String {
            switch self {
            case .mb: return "MB"
            case .kb: return "KB"
            case .bytes: return "Bytes"
            }
        }
    }
    enum Importance: CaseIterable { case unchanged, always, never }

    /// Gmail Web's "Categorize as" choices, in its order.
    static let categories: [(id: String, title: String)] = [
        ("CATEGORY_PERSONAL", "Primary"),
        ("CATEGORY_SOCIAL", "Social"),
        ("CATEGORY_UPDATES", "Updates"),
        ("CATEGORY_FORUMS", "Forums"),
        ("CATEGORY_PROMOTIONS", "Promotions"),
    ]

    // Criteria
    var from = ""
    var to = ""
    var subject = ""
    var hasWords = ""
    var doesNotHave = ""
    var hasAttachment = false
    var sizeComparison: SizeComparison = .larger
    /// Empty: no size criterion, as in Gmail Web.
    var sizeValue = ""
    var sizeUnit: SizeUnit = .mb

    // Actions
    var skipInbox = false
    var markRead = false
    var star = false
    /// A user label id (`Label_…`), or nil.
    var labelId: String?
    var delete = false
    var neverSpam = false
    var importance: Importance = .unchanged
    var category: String?

    // Kept from the original, listed read-only in the sheet.
    var keptAddLabelIds: [String] = []
    var keptRemoveLabelIds: [String] = []
    var excludeChats: Bool?
    /// The original's forwarding address, shown only. Never encoded: such a
    /// filter is not saved from here (`problem`, `GmailClient.createFilter`).
    var forward: String?

    /// Longest text accepted in one criterion field.
    static let maxFieldLength = 1_500

    init() {}

    init(_ filter: GFilter) {
        let c = filter.criteria
        from = c?.from ?? ""
        to = c?.to ?? ""
        subject = c?.subject ?? ""
        hasWords = c?.query ?? ""
        doesNotHave = c?.negatedQuery ?? ""
        hasAttachment = c?.hasAttachment ?? false
        excludeChats = c?.excludeChats
        if let size = c?.size, size > 0 {
            sizeComparison = c?.sizeComparison == "smaller" ? .smaller : .larger
            let unit = SizeUnit.allCases.first { size % $0.rawValue == 0 } ?? .bytes
            sizeUnit = unit
            sizeValue = String(size / unit.rawValue)
        }
        for id in filter.action?.addLabelIds ?? [] {
            switch id {
            case "STARRED": star = true
            case "TRASH": delete = true
            case "IMPORTANT": importance = .always
            case _ where category == nil && Self.categories.contains(where: { $0.id == id }):
                category = id
            case _ where id.hasPrefix("Label_") && labelId == nil:
                labelId = id
            default: keptAddLabelIds.append(id)
            }
        }
        for id in filter.action?.removeLabelIds ?? [] {
            switch id {
            case "INBOX": skipInbox = true
            case "UNREAD": markRead = true
            case "SPAM": neverSpam = true
            case "IMPORTANT" where importance == .unchanged: importance = .never
            default: keptRemoveLabelIds.append(id)
            }
        }
        forward = filter.action?.forward
    }

    /// Size in bytes, nil when the field is empty or not a positive number.
    var sizeBytes: Int? {
        let text = sizeValue.trimmingCharacters(in: .whitespaces)
        guard let n = Int(text), n > 0 else { return nil }
        let (bytes, overflow) = n.multipliedReportingOverflow(by: sizeUnit.rawValue)
        return overflow || bytes > Int(Int32.max) ? nil : bytes
    }

    var criteria: GFilter.Criteria {
        let size = sizeBytes
        return GFilter.Criteria(
            from: Self.field(from), to: Self.field(to), subject: Self.field(subject),
            query: Self.field(hasWords), negatedQuery: Self.field(doesNotHave),
            hasAttachment: hasAttachment ? true : nil,
            size: size, sizeComparison: size == nil ? nil : sizeComparison.rawValue,
            excludeChats: excludeChats)
    }

    var action: GFilter.Action {
        var add: [String] = []
        var remove: [String] = []
        if skipInbox { remove.append("INBOX") }
        if markRead { remove.append("UNREAD") }
        if star { add.append("STARRED") }
        if let labelId { add.append(labelId) }
        if delete { add.append("TRASH") }
        if neverSpam { remove.append("SPAM") }
        switch importance {
        case .always: add.append("IMPORTANT")
        case .never: remove.append("IMPORTANT")
        case .unchanged: break
        }
        if let category { add.append(category) }
        add += keptAddLabelIds.filter { !add.contains($0) }
        remove += keptRemoveLabelIds.filter { !remove.contains($0) }
        return GFilter.Action(addLabelIds: add.isEmpty ? nil : add,
                              removeLabelIds: remove.isEmpty ? nil : remove,
                              forward: nil)
    }

    var body: GFilter.Body { GFilter.Body(criteria: criteria, action: action) }

    /// Forwarding needs gmail.settings.sharing, which MishMail does not ask
    /// for: such a filter is deleted here but edited in Gmail.
    var isForwarding: Bool { forward != nil }

    /// Actions kept from the original that the dialog has no control for.
    var hasHiddenActions: Bool { !keptAddLabelIds.isEmpty || !keptRemoveLabelIds.isEmpty }

    mutating func dropHiddenActions() {
        keptAddLabelIds = []
        keptRemoveLabelIds = []
    }

    /// Saving asks first: the filter deletes mail, or hides it as read.
    var needsConfirmation: Bool { delete || (skipInbox && markRead) }

    /// The first reason Gmail Web would not save this filter, or nil.
    var problem: String? {
        if isForwarding {
            return "This filter forwards mail. Edit it in Gmail."
        }
        if [from, to, subject, hasWords, doesNotHave].contains(where: { $0.count > Self.maxFieldLength }) {
            return "Each criterion can be at most \(Self.maxFieldLength) characters."
        }
        let sizeText = sizeValue.trimmingCharacters(in: .whitespaces)
        if !sizeText.isEmpty, sizeBytes == nil {
            return "Size must be a whole number greater than zero."
        }
        let c = criteria
        if c.from == nil, c.to == nil, c.subject == nil, c.query == nil,
           c.negatedQuery == nil, c.hasAttachment == nil, c.size == nil {
            return "Specify at least one search criterion."
        }
        let a = action
        if (a.addLabelIds ?? []).isEmpty, (a.removeLabelIds ?? []).isEmpty, a.forward == nil {
            return "Choose at least one action."
        }
        return nil
    }

    private static func field(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Local preview

/// Which local messages a draft's criteria would match, with the same
/// best-effort rules as the matching-filters disclosure (`GmailFilterMatch`).
enum GmailFilterPreview {
    /// Most recent messages scanned; keeps the read cheap on large caches.
    static let scanLimit = 500
    /// Hits listed in the sheet.
    static let shownLimit = 20

    struct Hit: Equatable, Identifiable {
        let id: String
        let from: String
        let subject: String
        let date: Date
    }

    struct Result: Equatable {
        var scanned: Int
        var matchCount: Int
        var hits: [Hit]
        /// Local rows carry no size, so a size criterion matches nothing here.
        var sizeNotChecked: Bool
    }

    static func evaluate(_ criteria: GFilter.Criteria,
                         messages: [(hit: Hit, fields: GmailFilterMatch.MessageFields)]) -> Result {
        let matched = messages.filter { GmailFilterMatch.matches(criteria, message: $0.fields) }
        return Result(scanned: messages.count, matchCount: matched.count,
                      hits: matched.prefix(shownLimit).map(\.hit),
                      sizeNotChecked: criteria.size != nil)
    }

    /// Labels whose messages a filter never sees: it runs on incoming mail,
    /// and Gmail Web's filter search leaves Trash and Spam out.
    static let excludedLabels: Set<String> = ["TRASH", "SPAM", "SENT", "DRAFT"]

    /// The account's most recent received messages outside Trash and Spam.
    static func fetch(_ db: Database, account: String,
                      criteria: GFilter.Criteria) throws -> Result {
        let rows = try Message.fetchAll(db, sql: """
            SELECT * FROM message WHERE accountId = ?
            ORDER BY date DESC LIMIT ?
            """, arguments: [account, scanLimit * 2])
            .filter { message in
                let labels = Set(message.labelIds.split(separator: " ").map(String.init))
                return labels.isDisjoint(with: excludedLabels)
            }
            .prefix(scanLimit)
        // Bodies live off-row since v24; only free-text criteria read them.
        var bodyById: [String: String] = [:]
        if criteria.query != nil || criteria.negatedQuery != nil {
            let bodies = try MessageBody.fetchAll(db, keys: rows.map(\.id))
            bodyById = Dictionary(bodies.map { ($0.messageId, $0.bodyText) },
                                  uniquingKeysWith: { first, _ in first })
        }
        let messages = rows.map { row -> (hit: Hit, fields: GmailFilterMatch.MessageFields) in
            var message = row
            if message.bodyText.isEmpty { message.bodyText = bodyById[message.id] ?? "" }
            return (Hit(id: message.id, from: message.fromHeader,
                        subject: message.subject, date: message.date),
                    GmailFilterMatch.MessageFields(message))
        }
        return evaluate(criteria, messages: messages)
    }
}
