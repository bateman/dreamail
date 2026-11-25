import Foundation
import GRDB

/// Gmail's `messageListVisibility`: whether conversations in the message
/// list show the label's chip.
enum MessageListVisibility: String, Sendable {
    case show
    case hide

    /// No value (a label synced before v66) or an unknown one reads as
    /// Gmail's default.
    init(raw: String?) {
        self = raw.flatMap(MessageListVisibility.init(rawValue:)) ?? .show
    }
}

/// What a `labels.patch` from the label menu changes besides the color:
/// only the fields set are sent.
struct GmailLabelPatch: Equatable, Sendable {
    var name: String? = nil
    var labelListVisibility: SidebarLabelNode.Visibility? = nil
    var messageListVisibility: MessageListVisibility? = nil

    var body: [String: Any] {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let labelListVisibility { body["labelListVisibility"] = labelListVisibility.rawValue }
        if let messageListVisibility { body["messageListVisibility"] = messageListVisibility.rawValue }
        return body
    }
}

/// The Gmail calls the label menu makes. `GmailClient` in the app; a stub
/// in the tests and in the demo mailbox, so nothing reaches the network.
protocol LabelRemote: Sendable {
    func patchLabel(id: String, _ patch: GmailLabelPatch) async throws -> GLabel
    func deleteLabel(id: String) async throws
    /// The label as Gmail has it now (`labels.get`).
    func label(id: String) async throws -> GLabel
}

extension GmailClient: LabelRemote {}

/// The demo mailbox has no Gmail behind it: every edit "succeeds" and the
/// local rows carry it.
struct DemoLabelRemote: LabelRemote {
    func patchLabel(id: String, _ patch: GmailLabelPatch) async throws -> GLabel {
        GLabel(id: id, name: patch.name ?? "", type: "user", color: nil,
               labelListVisibility: patch.labelListVisibility?.rawValue,
               messageListVisibility: patch.messageListVisibility?.rawValue)
    }

    func deleteLabel(id: String) async throws {}

    func label(id: String) async throws -> GLabel {
        GLabel(id: id, name: "", type: "user", color: nil)
    }
}

/// A label name as text that cannot mislead in a title, an alert or a
/// VoiceOver label: control and line-separator characters (a newline that
/// fakes a second line) and bidirectional formatting characters (which
/// reorder what is shown) are written as visible `U+XXXX` escapes. Show it
/// with `Text(verbatim:)`, so `*a*` or `[x](y)` is not read as Markdown.
enum LabelText {
    static func safe(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            let v = scalar.value
            let bidi = (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
                || [0x200E, 0x200F, 0x061C].contains(v)
            let category = scalar.properties.generalCategory
            if category == .control || category == .lineSeparator || category == .paragraphSeparator
                || bidi {
                out += String(format: "\u{27E8}U+%04X\u{27E9}", v)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// `“name”`, made safe.
    static func quoted(_ name: String) -> String { "“\(safe(name))”" }
}

/// A label and the labels nested under it. Gmail labels are flat names:
/// `a/b/c` is nested under `a` because its name starts with `a/`, whether
/// or not `a/b` exists. `Bandi2` is not under `Bandi`.
enum LabelFamily {
    /// `label` first, then every label of its account nested under it at
    /// any depth, parents before their children.
    static func members(of label: LabelRow, in rows: [LabelRow]) -> [LabelRow] {
        [label] + descendants(of: label, in: rows)
    }

    static func descendants(of label: LabelRow, in rows: [LabelRow]) -> [LabelRow] {
        let prefix = label.name + "/"
        return rows
            .filter { $0.accountId == label.accountId && $0.id != label.id && $0.name.hasPrefix(prefix) }
            // A parent's name is a proper prefix of its child's, so it sorts first.
            .sorted { $0.name < $1.name }
    }

    /// How deep a label sits under `label`: 1 for `a/b` under `a`.
    static func depth(of row: LabelRow, under label: LabelRow) -> Int {
        row.name.dropFirst(label.name.count).filter { $0 == "/" }.count
    }
}

/// Runs Gmail calls with a cap on how many are in flight (one account, one
/// Gmail client, one quota bucket).
enum LabelBatch {
    static let maxInFlight = 4

    /// The indexes of the items whose call threw, with the error.
    static func run<Item: Sendable>(_ items: [Item],
                                    body: @escaping @Sendable (Item) async throws -> Void)
        async -> [Int: Error] {
        let box = FailureBox()
        await BoundedLanes.run(Array(items.enumerated()).map { IndexedItem(index: $0.offset, item: $0.element) },
                               maxInFlight: maxInFlight, lane: { _ in "" }) { entry in
            do {
                try await body(entry.item)
            } catch {
                box.add(entry.index, error)
            }
        }
        return box.all
    }

    private struct IndexedItem<Item: Sendable>: Sendable {
        let index: Int
        let item: Item
    }

    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var failures: [Int: Error] = [:]
        func add(_ index: Int, _ error: Error) { lock.withLock { failures[index] = error } }
        var all: [Int: Error] { lock.withLock { failures } }
    }
}

// MARK: - Edit (rename, nest under)

/// Gmail's "Edit label" dialog: a new name and a new parent. Renaming or
/// moving a label renames every label nested under it too (Gmail web does
/// the same: the names are paths).
enum LabelRename {
    struct Change: Equatable, Sendable {
        let rowId: String
        let gmailLabelId: String
        let from: String
        let to: String
    }

    enum Problem: Error, Equatable {
        case empty
        case unchanged
        case duplicate
        /// Nested under itself or one of its own sublabels.
        case intoItself
        /// The parent is not one of this account's labels.
        case unknownParent

        var message: String {
            switch self {
            case .empty: return "Enter a label name."
            case .unchanged: return "The label already has this name."
            case .duplicate: return "A label with this name already exists."
            case .intoItself: return "A label can't be nested under itself or its sublabels."
            case .unknownParent: return "Choose a label of this account to nest it under."
            }
        }
    }

    /// The renames that give `label` the name `name` under `parent` (nil:
    /// top level), its sublabels first moved along with it, parent first.
    static func plan(label: LabelRow, name: String, parent: String?,
                     rows: [LabelRow]) -> Result<[Change], Problem> {
        let own = rows.filter { $0.accountId == label.accountId }
        if let parent, !parent.isEmpty {
            if parent == label.name || parent.hasPrefix(label.name + "/") { return .failure(.intoItself) }
            if !own.contains(where: { $0.name == parent }) { return .failure(.unknownParent) }
        }
        guard let full = NewLabelName.full(name: name, parent: parent) else { return .failure(.empty) }
        guard full != label.name else { return .failure(.unchanged) }
        let family = LabelFamily.members(of: label, in: own)
        let familyIds = Set(family.map(\.id))
        let others = own.filter { !familyIds.contains($0.id) }
        let changes = family.map { row in
            Change(rowId: row.id, gmailLabelId: row.gmailLabelId, from: row.name,
                   to: full + row.name.dropFirst(label.name.count))
        }
        // Gmail refuses a name another label has, ignoring case.
        if changes.contains(where: { NewLabelName.exists($0.to, in: others) }) {
            return .failure(.duplicate)
        }
        return .success(changes)
    }

    enum Outcome {
        case renamed
        /// Some renames failed even after a retry; the ones that had landed
        /// were put back, so every label has its old name again.
        case rolledBack(cause: Error)
        /// Some renames failed and some of the landed ones could not be put
        /// back either: `renamed` have the new name on Gmail, `notRenamed`
        /// the old one.
        case partial(renamed: [Change], notRenamed: [Change], cause: Error)
    }

    /// Sends the renames (bounded), retries the failed ones once, and when
    /// some still fail undoes the ones that landed, so the tree does not end
    /// half moved. `store` gets each label's name on Gmail as far as known.
    static func execute(_ changes: [Change], remote: LabelRemote) async -> (Outcome, names: [String: String]) {
        var names = Dictionary(uniqueKeysWithValues: changes.map { ($0.rowId, $0.from) })
        var failures = await send(changes, forward: true, remote: remote)
        if !failures.isEmpty {
            let retry = failures.keys.sorted().map { changes[$0] }
            let again = await send(retry, forward: true, remote: remote)
            failures = Dictionary(uniqueKeysWithValues: again.map { (changes.firstIndex(of: retry[$0.key])!, $0.value) })
        }
        guard let cause = failures.values.first else {
            for c in changes { names[c.rowId] = c.to }
            return (.renamed, names)
        }
        let landed = changes.indices.filter { failures[$0] == nil }.map { changes[$0] }
        let undoFailures = await send(landed, forward: false, remote: remote)
        let stuck = undoFailures.keys.sorted().map { landed[$0] }
        guard !stuck.isEmpty else { return (.rolledBack(cause: cause), names) }
        for c in stuck { names[c.rowId] = c.to }
        let stuckIds = Set(stuck.map(\.rowId))
        return (.partial(renamed: stuck, notRenamed: changes.filter { !stuckIds.contains($0.rowId) },
                         cause: cause), names)
    }

    private static func send(_ changes: [Change], forward: Bool,
                             remote: LabelRemote) async -> [Int: Error] {
        await LabelBatch.run(changes) { c in
            let target = forward ? c.to : c.from
            do {
                _ = try await remote.patchLabel(id: c.gmailLabelId, GmailLabelPatch(name: target))
            } catch {
                // "Name exists": not a failure when the label itself already
                // has that name on Gmail (a parent's rename carried it along,
                // or an earlier attempt landed after its answer was lost).
                guard isNameConflict(error),
                      let current = try? await remote.label(id: c.gmailLabelId),
                      current.name == target else { throw error }
            }
        }
    }

    static func isNameConflict(_ error: Error) -> Bool {
        if case GmailError.http(409, _) = error { return true }
        return false
    }

    /// Stores the names Gmail has, in one transaction.
    static func store(_ db: Database, names: [String: String]) throws {
        for (id, name) in names {
            try db.execute(sql: "UPDATE label SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }
}

// MARK: - Remove

/// Gmail web's "Remove label": the label and every label nested under it
/// go; conversations stay and only lose the labels. The API deletes one
/// label per call, so each sublabel is deleted on its own, deepest first.
enum LabelRemoval {
    /// The rows to delete, deepest first, the label itself last.
    static func order(_ label: LabelRow, rows: [LabelRow]) -> [LabelRow] {
        let family = LabelFamily.members(of: label, in: rows)
        return family.sorted {
            let a = LabelFamily.depth(of: $0, under: label), b = LabelFamily.depth(of: $1, under: label)
            return a != b ? a > b : $0.name < $1.name
        }
    }

    struct Report {
        var deleted: [LabelRow] = []
        var notDeleted: [LabelRow] = []
        var cause: Error?
    }

    /// Deletes level by level from the deepest; a level with a failure
    /// stops the shallower ones, so a parent never goes while a sublabel
    /// it holds stays behind.
    static func execute(_ rows: [LabelRow], under label: LabelRow,
                        remote: LabelRemote) async -> Report {
        var result = Report()
        let levels = Dictionary(grouping: rows) { LabelFamily.depth(of: $0, under: label) }
        for depth in levels.keys.sorted(by: >) {
            let level = levels[depth] ?? []
            guard result.cause == nil else {
                result.notDeleted += level
                continue
            }
            let failures = await LabelBatch.run(level) { row in
                try await remote.deleteLabel(id: row.gmailLabelId)
            }
            for (i, row) in level.enumerated() {
                if failures[i] == nil { result.deleted.append(row) } else { result.notDeleted.append(row) }
            }
            if let first = failures.keys.min() { result.cause = failures[first] }
        }
        return result
    }

    /// The label to remove, as it is now: nil when it is gone or has
    /// another name than when the confirmation was asked (a sync landed a
    /// rename made elsewhere meanwhile). Never act on the snapshot: its id
    /// could now be another label than the one the dialog named.
    static func resolve(_ snapshot: LabelRow, current rows: [LabelRow]) -> LabelRow? {
        guard let row = rows.first(where: { $0.id == snapshot.id }),
              row.name == snapshot.name, row.accountId == snapshot.accountId else { return nil }
        return row
    }

    /// Saved views that show (or exclude) one of the removed labels: they go
    /// with them (DEC-019). A view of every account goes only when no other
    /// account still has a label with that id (ids are per account).
    static func viewsUsing(_ removed: [LabelRow], views: [SavedView],
                           allLabels: [LabelRow]) -> [SavedView] {
        guard let account = removed.first?.accountId else { return [] }
        let ids = Set(removed.map(\.gmailLabelId))
        let elsewhere = Set(allLabels.filter { $0.accountId != account }.map(\.gmailLabelId))
        return views.filter { view in
            let chipLabel = view.chipsJSON.flatMap { try? JSONDecoder().decode(FilterChips.self, from: $0) }?.labelId
            let used = [view.labelId, chipLabel].compactMap { $0 }.filter(ids.contains)
            guard !used.isEmpty else { return false }
            if view.accountId == account { return true }
            return view.accountId == nil && used.allSatisfy { !elsewhere.contains($0) }
        }
    }

    /// "Deleted means gone" (DEC-019): the rows, the conversations'
    /// memberships and the saved views on them go. The label's color only
    /// on this Mac and its order are columns of the row; what UserDefaults
    /// keeps per label goes with `forgetDefaults`.
    static func forget(_ db: Database, rows: [LabelRow], views: [SavedView] = []) throws {
        for row in rows {
            try db.execute(sql: """
                DELETE FROM thread_label
                WHERE labelId = ? AND threadId IN (SELECT id FROM thread WHERE accountId = ?)
                """, arguments: [row.gmailLabelId, row.accountId])
            try db.execute(sql: "DELETE FROM label WHERE id = ?", arguments: [row.id])
        }
        for view in views {
            if let id = view.id { _ = try SavedView.deleteOne(db, key: id) }
        }
    }

    /// The per-label keys in UserDefaults: the disclosure state and the
    /// label view's saved category filter.
    static func forgetDefaults(_ rows: [LabelRow], _ defaults: UserDefaults = .standard) {
        for row in rows {
            SidebarDisclosure.forget(row.gmailLabelId, accountId: row.accountId, defaults)
            let view = MailboxView.label(account: row.accountId, labelId: row.gmailLabelId, name: row.name)
            if let key = view.prefsKey { defaults.removeObject(forKey: "categoryFilter.\(key)") }
        }
    }
}

/// What the Remove confirmation says, as Gmail web does: the label and its
/// sublabels go, the conversations stay.
enum LabelRemovalText {
    /// The title; names the account when there is more than one (two
    /// accounts can both have "Work").
    static func title(label: LabelRow, multipleAccounts: Bool) -> String {
        multipleAccounts
            ? "Remove label \(LabelText.quoted(label.name)) from \(LabelText.safe(label.accountId))?"
            : "Remove label \(LabelText.quoted(label.name))?"
    }

    static func message(label: LabelRow, sublabels: Int, savedViews: Int = 0) -> String {
        var parts: [String] = []
        switch sublabels {
        case 0: break
        case 1: parts.append("Its sublabel is removed too.")
        default: parts.append("Its \(sublabels) sublabels are removed too.")
        }
        switch savedViews {
        case 0: break
        case 1: parts.append("The saved view that uses it is removed too.")
        default: parts.append("The \(savedViews) saved views that use it are removed too.")
        }
        parts.append("Conversations are not deleted: they only lose the label.")
        parts.append("This can't be undone.")
        return parts.joined(separator: " ")
    }
}

// MARK: - Visibility

/// "In label list" and "In message list": shown at once, put back if Gmail
/// refuses.
enum LabelVisibilityEdit {
    static func apply(_ patch: GmailLabelPatch, rowId: String, db: any DatabaseWriter,
                      didStore: () async -> Void = {},
                      remote: LabelRemote) async throws {
        let before = try await db.write { db -> LabelRow in
            guard let row = try LabelRow.fetchOne(db, key: rowId) else {
                throw GmailLabelColorEdit.Failure.unknownLabel
            }
            try store(db, patch, rowId: rowId)
            return row
        }
        await didStore()
        do {
            _ = try await remote.patchLabel(id: before.gmailLabelId, patch)
        } catch {
            try? await db.write { db in
                try store(db, GmailLabelPatch(
                    labelListVisibility: patch.labelListVisibility == nil ? nil
                        : SidebarLabelNode.Visibility(raw: before.listVisibility),
                    messageListVisibility: patch.messageListVisibility == nil ? nil
                        : MessageListVisibility(raw: before.messageListVisibility)),
                    rowId: rowId)
            }
            throw error
        }
    }

    private static func store(_ db: Database, _ patch: GmailLabelPatch, rowId: String) throws {
        if let v = patch.labelListVisibility {
            try db.execute(sql: "UPDATE label SET listVisibility = ? WHERE id = ?",
                           arguments: [v.rawValue, rowId])
        }
        if let v = patch.messageListVisibility {
            try db.execute(sql: "UPDATE label SET messageListVisibility = ? WHERE id = ?",
                           arguments: [v.rawValue, rowId])
        }
    }
}

// MARK: - Color cascade

extension GmailLabelColorEdit {
    /// The labels whose Gmail color did not change, and the first reason.
    struct CascadeResult {
        var failed: [String] = []
        var cause: Error?
    }

    /// Sets (or removes) the Gmail color of several labels: a parent and
    /// its sublabels. One transaction stores every new color, `didStore`
    /// runs once (one tree rebuild), then one `labels.patch` per label goes
    /// out, at most `LabelBatch.maxInFlight` at a time; one transaction
    /// keeps Gmail's answers and puts back the colors of the labels whose
    /// call failed.
    static func applyMany(_ target: GmailLabelColor?,
                          labelRowIds ids: [String],
                          db: any DatabaseWriter,
                          pending: PendingLabelColorEdits = .shared,
                          now: () -> Date = { Date() },
                          didStore: () async -> Void = {},
                          patch: @escaping @Sendable (_ gmailLabelId: String, _ color: GmailLabelColor?)
                              async throws -> GLabel) async -> CascadeResult {
        let wanted = target?.colors ?? .none
        var result = CascadeResult()
        let begun = ClaimBox()
        let claims: [Claim]
        do {
            let (claimed, refused, cause) = try await db.write { db -> ([Claim], [String], Error?) in
                var claimed: [Claim] = []
                var refused: [String] = []
                var cause: Error?
                for id in ids {
                    guard let row = try LabelRow.fetchOne(db, key: id) else {
                        refused.append(id); cause = cause ?? Failure.unknownLabel; continue
                    }
                    guard row.type == "user" else {
                        refused.append(id); cause = cause ?? Failure.systemLabel; continue
                    }
                    guard pending.begin(id, colors: wanted) else {
                        refused.append(id); cause = cause ?? Failure.inFlight; continue
                    }
                    begun.add(id)
                    try store(db, wanted, id: id)
                    claimed.append(Claim(id: id, gmailLabelId: row.gmailLabelId,
                                         before: LabelColors(background: row.gmailBackgroundColor,
                                                             text: row.gmailTextColor)))
                }
                return (claimed, refused, cause)
            }
            claims = claimed
            result.failed = refused
            result.cause = cause
        } catch {
            // Rolled back: release only the edits this call started.
            for id in begun.all { pending.cancel(id) }
            return CascadeResult(failed: ids, cause: error)
        }
        guard !claims.isEmpty else { return result }
        await didStore()
        let answers = AnswerBox()
        let failures = await LabelBatch.run(claims) { claim in
            answers.set(claim.id, try await patch(claim.gmailLabelId, target))
        }
        let got = answers.all
        let stamp = now()
        let notApplied = (try? await db.write { db -> [String] in
            var notApplied: [String] = []
            for (i, claim) in claims.enumerated() {
                if failures[i] == nil, let answer = got[claim.id] {
                    let confirmed = colors(of: answer)
                    try store(db, confirmed, id: claim.id)
                    pending.confirm(claim.id, colors: confirmed, now: stamp)
                    if confirmed != wanted { notApplied.append(claim.id) }
                } else {
                    pending.cancel(claim.id)
                    // Only over our own write: a sync may have stored newer colors.
                    try db.execute(sql: """
                        UPDATE label SET gmailBackgroundColor = ?, gmailTextColor = ?
                        WHERE id = ? AND gmailBackgroundColor IS ? AND gmailTextColor IS ?
                        """, arguments: [claim.before.background, claim.before.text, claim.id,
                                         wanted.background, wanted.text])
                }
            }
            return notApplied
        }) ?? []
        for (i, claim) in claims.enumerated() where failures[i] != nil {
            result.failed.append(claim.id)
            result.cause = result.cause ?? failures[i]
        }
        if !notApplied.isEmpty {
            result.failed += notApplied
            result.cause = result.cause ?? Failure.notApplied
        }
        return result
    }

    /// The color only on this Mac (DEC-023) of several labels, in one
    /// transaction.
    static func setLocalColor(_ db: Database, hex: String?, labelRowIds ids: [String]) throws {
        for id in ids {
            try db.execute(sql: "UPDATE label SET color = ? WHERE id = ?", arguments: [hex, id])
        }
    }

    private struct Claim: Sendable {
        let id: String
        let gmailLabelId: String
        let before: LabelColors
    }

    private final class ClaimBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }

    private final class AnswerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: GLabel] = [:]
        func set(_ id: String, _ label: GLabel) { lock.withLock { answers[id] = label } }
        var all: [String: GLabel] { lock.withLock { answers } }
    }
}
