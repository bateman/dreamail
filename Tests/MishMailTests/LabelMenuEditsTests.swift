import XCTest
import GRDB

/// The sidebar's label menu: a parent's color going to its sublabels, the
/// Edit dialog's rename and move, Remove with sublabels, both visibilities,
/// and the v66 migration. No network: Gmail is a stub.
final class LabelMenuEditsTests: XCTestCase {
    private let a = "a@x.com"
    private let b = "b@x.com"

    /// Records labels.patch and labels.delete calls; fails the ones asked.
    final class FakeRemote: LabelRemote, @unchecked Sendable {
        private let lock = NSLock()
        private var patchCalls: [(String, GmailLabelPatch)] = []
        private var deleteCalls: [String] = []
        /// Returns the error a call should throw, nil to succeed.
        var failPatch: @Sendable (String, GmailLabelPatch, Int) -> Error? = { _, _, _ in nil }
        var failDelete: @Sendable (String) -> Error? = { _ in nil }

        var patches: [(String, GmailLabelPatch)] { lock.withLock { patchCalls } }
        var deletes: [String] { lock.withLock { deleteCalls } }

        func patchLabel(id: String, _ patch: GmailLabelPatch) async throws -> GLabel {
            let attempt: Int = lock.withLock {
                patchCalls.append((id, patch))
                return patchCalls.filter { $0.0 == id && $0.1 == patch }.count
            }
            if let error = failPatch(id, patch, attempt) { throw error }
            return GLabel(id: id, name: patch.name ?? "", type: "user", color: nil,
                          labelListVisibility: patch.labelListVisibility?.rawValue,
                          messageListVisibility: patch.messageListVisibility?.rawValue)
        }

        func deleteLabel(id: String) async throws {
            lock.withLock { deleteCalls.append(id) }
            if let error = failDelete(id) { throw error }
        }
    }

    private struct Refused: Error {}

    private func row(_ id: String, _ name: String, account: String = "a@x.com") -> LabelRow {
        LabelRow(id: "\(account):\(id)", accountId: account, gmailLabelId: id, name: name,
                 type: "user", color: nil)
    }

    /// `Bandi` with sublabels at three depths, the look-alike `Bandi2` with
    /// its own sublabel, another label, and `Bandi` on a second account.
    private var rows: [LabelRow] {
        [row("L1", "Bandi"), row("L2", "Bandi/PRIN"), row("L3", "Bandi/PRIN/2025"),
         row("L4", "Bandi/PRIN/2025/Esiti"), row("L5", "Bandi2"), row("L6", "Bandi2/x"),
         row("L7", "Work"), row("L1", "Bandi/other", account: b)]
    }

    private func makeDB(_ labels: [LabelRow]? = nil) throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            for id in [a, b] {
                try Account(id: id, displayName: "P", historyId: nil,
                            lastSyncAt: nil, senderName: "").insert(db)
            }
            for label in labels ?? self.rows { try label.insert(db) }
        }
        return q
    }

    private func stored(_ q: DatabaseQueue) throws -> [String: LabelRow] {
        let all = try q.read { try LabelRow.fetchAll($0) }
        return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }

    private func id(_ gmailId: String, _ account: String = "a@x.com") -> String { "\(account):\(gmailId)" }

    // MARK: Family

    func testFamilyIsTheLabelAndEveryDepthButNotALookAlike() {
        let bandi = rows[0]
        XCTAssertEqual(LabelFamily.members(of: bandi, in: rows).map(\.name),
                       ["Bandi", "Bandi/PRIN", "Bandi/PRIN/2025", "Bandi/PRIN/2025/Esiti"])
        XCTAssertEqual(LabelFamily.members(of: rows[4], in: rows).map(\.name), ["Bandi2", "Bandi2/x"])
        XCTAssertEqual(LabelFamily.members(of: rows[3], in: rows).map(\.name), ["Bandi/PRIN/2025/Esiti"])
    }

    /// A missing level does not cut the family: `a/b/c` is under `a`.
    func testFamilyFollowsTheNameNotTheExistingLevels() {
        let labels = [row("L1", "a"), row("L2", "a/b/c")]
        XCTAssertEqual(LabelFamily.members(of: labels[0], in: labels).map(\.name), ["a", "a/b/c"])
    }

    // MARK: Color cascade

    private let blue = GmailLabelColor(background: "#4a86e8", text: "#ffffff")!

    private func answer(_ id: String, _ color: GmailLabelColor?) -> GLabel {
        GLabel(id: id, name: "n", type: "user",
               color: color.map { GLabel.GColor(backgroundColor: $0.background, textColor: $0.text) })
    }

    func testGmailColorGoesToEverySublabelAndNotToALookAlike() async throws {
        let q = try makeDB()
        let family = LabelFamily.members(of: rows[0], in: rows).map(\.id)
        let pending = PendingLabelColorEdits()
        var stores = 0
        let blue = self.blue
        let result = await GmailLabelColorEdit.applyMany(
            blue, labelRowIds: family, db: q, pending: pending,
            didStore: { stores += 1 }) { id, color in
                self.answer(id, color)
            }
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertNil(result.cause)
        XCTAssertEqual(stores, 1, "one optimistic store for the whole cascade: one tree rebuild")
        let after = try stored(q)
        for rowId in family {
            XCTAssertEqual(after[rowId]?.gmailBackgroundColor, "#4a86e8", rowId)
            XCTAssertEqual(after[rowId]?.gmailTextColor, "#ffffff", rowId)
        }
        for rowId in [id("L5"), id("L6"), id("L7"), id("L1", b)] {
            XCTAssertNil(after[rowId]?.gmailBackgroundColor, rowId)
        }
    }

    func testCascadeRemovesTheColorToo() async throws {
        var labels = rows
        for i in labels.indices {
            labels[i].gmailBackgroundColor = "#4a86e8"
            labels[i].gmailTextColor = "#ffffff"
        }
        let q = try makeDB(labels)
        let family = LabelFamily.members(of: labels[0], in: labels).map(\.id)
        let result = await GmailLabelColorEdit.applyMany(
            nil, labelRowIds: family, db: q, pending: PendingLabelColorEdits()) { id, _ in
                self.answer(id, nil)
            }
        XCTAssertTrue(result.failed.isEmpty)
        let after = try stored(q)
        for rowId in family { XCTAssertNil(after[rowId]?.gmailBackgroundColor, rowId) }
        XCTAssertEqual(after[id("L5")]?.gmailBackgroundColor, "#4a86e8")
    }

    /// One sublabel's patch fails: only that one keeps its old color, and it
    /// is named for the retry.
    func testCascadePartialFailurePutsBackOnlyTheFailedLabel() async throws {
        var labels = rows
        labels[2].gmailBackgroundColor = "#fad165"
        labels[2].gmailTextColor = "#000000"
        let q = try makeDB(labels)
        let family = LabelFamily.members(of: labels[0], in: labels).map(\.id)
        let pending = PendingLabelColorEdits()
        let result = await GmailLabelColorEdit.applyMany(
            blue, labelRowIds: family, db: q, pending: pending) { id, color in
                if id == "L3" { throw Refused() }
                return self.answer(id, color)
            }
        XCTAssertEqual(result.failed, [id("L3")])
        XCTAssertTrue(result.cause is Refused)
        let after = try stored(q)
        XCTAssertEqual(after[id("L3")]?.gmailBackgroundColor, "#fad165", "the failed one is put back")
        for gmailId in ["L1", "L2", "L4"] {
            XCTAssertEqual(after[id(gmailId)]?.gmailBackgroundColor, "#4a86e8", gmailId)
        }
        // Nothing left in flight: a retry may start again.
        XCTAssertTrue(pending.begin(id("L3"), colors: blue.colors))
    }

    /// A label already being saved is not sent twice and is reported.
    func testCascadeSkipsALabelInFlight() async throws {
        let q = try makeDB()
        let pending = PendingLabelColorEdits()
        XCTAssertTrue(pending.begin(id("L2"), colors: .none))
        let family = LabelFamily.members(of: rows[0], in: rows).map(\.id)
        let seen = Seen()
        let result = await GmailLabelColorEdit.applyMany(
            blue, labelRowIds: family, db: q, pending: pending) { id, color in
                seen.add(id)
                return self.answer(id, color)
            }
        XCTAssertEqual(result.failed, [id("L2")])
        XCTAssertEqual(result.cause as? GmailLabelColorEdit.Failure, .inFlight)
        XCTAssertEqual(Set(seen.all), ["L1", "L3", "L4"])
    }

    /// The patches are bounded: never more than `LabelBatch.maxInFlight`.
    func testCascadeIsBounded() async throws {
        var labels = [row("P", "p")]
        for i in 0..<20 { labels.append(row("C\(i)", "p/c\(i)")) }
        let q = try makeDB(labels)
        let gauge = Gauge()
        let result = await GmailLabelColorEdit.applyMany(
            blue, labelRowIds: labels.map(\.id), db: q, pending: PendingLabelColorEdits()) { id, color in
                gauge.enter()
                try await Task.sleep(nanoseconds: 2_000_000)
                gauge.leave()
                return self.answer(id, color)
            }
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertLessThanOrEqual(gauge.peak, LabelBatch.maxInFlight)
        XCTAssertGreaterThan(gauge.peak, 0)
    }

    func testMacOnlyColorGoesToEverySublabel() throws {
        let q = try makeDB()
        let family = LabelFamily.members(of: rows[0], in: rows).map(\.id)
        try q.write { db in
            try GmailLabelColorEdit.setLocalColor(db, hex: "#EB5757", labelRowIds: family)
        }
        var after = try stored(q)
        for rowId in family { XCTAssertEqual(after[rowId]?.color, "#EB5757", rowId) }
        XCTAssertNil(after[id("L5")]?.color)
        XCTAssertNil(after[id("L1", b)]?.color)

        // A sublabel's own later color stays until the parent changes again.
        try q.write { db in
            try GmailLabelColorEdit.setLocalColor(db, hex: "#27AE60", labelRowIds: [self.id("L3")])
        }
        after = try stored(q)
        XCTAssertEqual(after[id("L3")]?.color, "#27AE60")
        XCTAssertEqual(after[id("L2")]?.color, "#EB5757")
        try q.write { db in
            try GmailLabelColorEdit.setLocalColor(db, hex: nil, labelRowIds: family)
        }
        after = try stored(q)
        for rowId in family { XCTAssertNil(after[rowId]?.color, rowId) }
    }

    // MARK: Edit: rename and move

    func testRenamingAParentRenamesEveryDescendantPath() throws {
        let changes = try LabelRename.plan(label: rows[0], name: "Calls", parent: nil, rows: rows).get()
        XCTAssertEqual(changes.map(\.to),
                       ["Calls", "Calls/PRIN", "Calls/PRIN/2025", "Calls/PRIN/2025/Esiti"])
        XCTAssertEqual(changes.map(\.gmailLabelId), ["L1", "L2", "L3", "L4"])
        XCTAssertFalse(changes.contains { $0.from.hasPrefix("Bandi2") }, "the look-alike is not touched")
    }

    func testNestingUnderAnotherLabelMovesTheSubtree() throws {
        let changes = try LabelRename.plan(label: rows[1], name: "PRIN", parent: "Work", rows: rows).get()
        XCTAssertEqual(changes.map(\.to), ["Work/PRIN", "Work/PRIN/2025", "Work/PRIN/2025/Esiti"])
        // Out of its parent, to the top level.
        let top = try LabelRename.plan(label: rows[1], name: "PRIN", parent: nil, rows: rows).get()
        XCTAssertEqual(top.map(\.to), ["PRIN", "PRIN/2025", "PRIN/2025/Esiti"])
    }

    func testRenameRefusesDuplicatesSelfNestingAndOtherAccountsParents() {
        func problem(_ label: LabelRow, _ name: String, _ parent: String?) -> LabelRename.Problem? {
            if case .failure(let p) = LabelRename.plan(label: label, name: name, parent: parent, rows: rows) {
                return p
            }
            return nil
        }
        XCTAssertEqual(problem(rows[0], "work", nil), .duplicate, "Gmail ignores case")
        XCTAssertEqual(problem(rows[0], "x", "Bandi/PRIN"), .intoItself)
        XCTAssertEqual(problem(rows[0], "x", "Bandi"), .intoItself)
        XCTAssertEqual(problem(rows[0], "x", "Nope"), .unknownParent)
        XCTAssertEqual(problem(rows[0], "  /", nil), .empty)
        XCTAssertEqual(problem(rows[0], "Bandi", nil), .unchanged)
        // A sublabel's new path must not hit another label either.
        let clash = rows + [row("L8", "Calls/PRIN")]
        if case .failure(let p) = LabelRename.plan(label: rows[0], name: "Calls", parent: nil, rows: clash) {
            XCTAssertEqual(p, .duplicate)
        } else {
            XCTFail("a descendant's new name clashes")
        }
        // Case only: not a duplicate of itself.
        XCTAssertNil(problem(rows[6], "WORK", nil))
    }

    func testRenameSendsEveryNameAndStoresThem() async throws {
        let q = try makeDB()
        let remote = FakeRemote()
        let changes = try LabelRename.plan(label: rows[0], name: "Calls", parent: nil, rows: rows).get()
        let (outcome, names) = await LabelRename.execute(changes, remote: remote)
        guard case .renamed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(Set(remote.patches.map(\.0)), ["L1", "L2", "L3", "L4"])
        try await q.write { db in try LabelRename.store(db, names: names) }
        let after = try stored(q)
        XCTAssertEqual(after[id("L4")]?.name, "Calls/PRIN/2025/Esiti")
        XCTAssertEqual(after[id("L5")]?.name, "Bandi2")
        XCTAssertEqual(after[id("L1", b)]?.name, "Bandi/other", "the other account is not touched")
    }

    /// A rename that fails once is retried and lands.
    func testRenameRetriesAFailureOnce() async throws {
        let remote = FakeRemote()
        remote.failPatch = { id, _, attempt in id == "L3" && attempt == 1 ? Refused() : nil }
        let changes = try LabelRename.plan(label: rows[0], name: "Calls", parent: nil, rows: rows).get()
        let (outcome, names) = await LabelRename.execute(changes, remote: remote)
        guard case .renamed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(names[id("L3")], "Calls/PRIN/2025")
    }

    /// One sublabel keeps failing: the landed renames are undone, so the
    /// tree is not left half moved.
    func testRenamePartialFailureRollsBack() async throws {
        let remote = FakeRemote()
        remote.failPatch = { id, patch, _ in id == "L3" && patch.name == "Calls/PRIN/2025" ? Refused() : nil }
        let changes = try LabelRename.plan(label: rows[0], name: "Calls", parent: nil, rows: rows).get()
        let (outcome, names) = await LabelRename.execute(changes, remote: remote)
        guard case .rolledBack = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(names, [id("L1"): "Bandi", id("L2"): "Bandi/PRIN", id("L3"): "Bandi/PRIN/2025",
                               id("L4"): "Bandi/PRIN/2025/Esiti"])
        let undone = remote.patches.filter { $0.1.name?.hasPrefix("Bandi") == true }.map(\.0)
        XCTAssertEqual(Set(undone), ["L1", "L2", "L4"])
    }

    /// The undo fails too: the outcome names what has which name.
    func testRenameRollbackFailureIsReported() async throws {
        let remote = FakeRemote()
        remote.failPatch = { id, patch, _ in
            if id == "L3" && patch.name == "Calls/PRIN/2025" { return Refused() }
            if id == "L1" && patch.name == "Bandi" { return Refused() }
            return nil
        }
        let changes = try LabelRename.plan(label: rows[0], name: "Calls", parent: nil, rows: rows).get()
        let (outcome, names) = await LabelRename.execute(changes, remote: remote)
        guard case .partial(let renamed, let notRenamed, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(renamed.map(\.gmailLabelId), ["L1"])
        XCTAssertEqual(Set(notRenamed.map(\.gmailLabelId)), ["L2", "L3", "L4"])
        XCTAssertEqual(names[id("L1")], "Calls")
        XCTAssertEqual(names[id("L2")], "Bandi/PRIN")
    }

    // MARK: Remove

    func testRemovalDeletesSublabelsDeepestFirst() {
        let order = LabelRemoval.order(rows[0], rows: rows).map(\.name)
        XCTAssertEqual(order, ["Bandi/PRIN/2025/Esiti", "Bandi/PRIN/2025", "Bandi/PRIN", "Bandi"])
    }

    func testRemovalDeletesTheFamilyAndForgetsIt() async throws {
        let q = try makeDB()
        try await q.write { db in
            for (t, label, account) in [("t1", "L2", self.a), ("t2", "L5", self.a), ("t3", "L1", self.b)] {
                try MailThread(
                    id: "\(account):\(t)", accountId: account, gmailThreadId: t,
                    subject: "s", snippet: "sn", fromDisplay: "F",
                    lastDate: Date(), isUnread: false, isStarred: false,
                    inInbox: true, inTrash: false,
                    labelIds: "INBOX \(label)", snoozeUntil: nil,
                    participants: "F", messageCount: 1, hasAttachment: false, reminderAt: nil,
                    inSpam: false).insert(db)
                try ThreadLabel(threadId: "\(account):\(t)", labelId: label).insert(db)
            }
        }
        let remote = FakeRemote()
        let family = LabelRemoval.order(rows[0], rows: rows)
        let report = await LabelRemoval.execute(family, under: rows[0], remote: remote)
        XCTAssertNil(report.cause)
        XCTAssertEqual(remote.deletes.last, "L1", "the label itself goes last")
        XCTAssertEqual(Set(remote.deletes), ["L1", "L2", "L3", "L4"])
        try await q.write { db in try LabelRemoval.forget(db, rows: report.deleted) }
        let after = try stored(q)
        for gmailId in ["L1", "L2", "L3", "L4"] { XCTAssertNil(after[id(gmailId)], gmailId) }
        XCTAssertNotNil(after[id("L5")])
        XCTAssertNotNil(after[id("L1", b)], "same Gmail id on another account stays")
        let memberships = try await q.read { db in
            try ThreadLabel.fetchAll(db).map { "\($0.threadId) \($0.labelId)" }.sorted()
        }
        XCTAssertEqual(memberships, ["a@x.com:t2 L5", "b@x.com:t3 L1"])
        let threads = try await q.read { try MailThread.fetchCount($0) }
        XCTAssertEqual(threads, 3, "conversations are kept")
    }

    /// A sublabel that cannot be deleted keeps its parent: nothing shallower
    /// is deleted, and the rest is reported for the retry.
    func testRemovalStopsAboveAFailure() async {
        let remote = FakeRemote()
        remote.failDelete = { $0 == "L3" ? Refused() : nil }
        let report = await LabelRemoval.execute(LabelRemoval.order(rows[0], rows: rows),
                                                under: rows[0], remote: remote)
        XCTAssertTrue(report.cause is Refused)
        XCTAssertEqual(report.deleted.map(\.gmailLabelId), ["L4"])
        XCTAssertEqual(Set(report.notDeleted.map(\.gmailLabelId)), ["L1", "L2", "L3"])
        XCTAssertFalse(remote.deletes.contains("L2"))
        XCTAssertFalse(remote.deletes.contains("L1"))
    }

    func testRemovalForgetsTheDisclosureState() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LabelMenuEditsTests.\(UUID())"))
        SidebarDisclosure.setLabel("L1", accountId: a, expanded: true, defaults)
        SidebarDisclosure.setLabel("L7", accountId: a, expanded: true, defaults)
        SidebarDisclosure.forget("L1", accountId: a, defaults)
        XCTAssertEqual(SidebarDisclosure.expandedLabels(accountId: a, defaults), ["L7"])
    }

    func testRemovalTextSaysSublabelsGoAndMessagesStay() {
        let text = LabelRemovalText.message(label: rows[0], sublabels: 3)
        XCTAssertTrue(text.contains("3 sublabels are removed too"), text)
        XCTAssertTrue(text.contains("Conversations are not deleted"), text)
        XCTAssertFalse(LabelRemovalText.message(label: rows[6], sublabels: 0).contains("sublabel"))
    }

    // MARK: Visibility

    func testBothVisibilitiesAreWrittenAndSent() async throws {
        let q = try makeDB()
        let remote = FakeRemote()
        try await LabelVisibilityEdit.apply(GmailLabelPatch(labelListVisibility: .hide),
                                            rowId: id("L7"), db: q, remote: remote)
        try await LabelVisibilityEdit.apply(GmailLabelPatch(messageListVisibility: .hide),
                                            rowId: id("L7"), db: q, remote: remote)
        let after = try XCTUnwrap(try stored(q)[id("L7")])
        XCTAssertEqual(after.listVisibility, "labelHide")
        XCTAssertEqual(after.messageListVisibility, "hide")
        XCTAssertFalse(after.showsInMessageList)
        XCTAssertEqual(remote.patches.map(\.0), ["L7", "L7"])
        XCTAssertEqual(remote.patches[0].1.body as NSDictionary, ["labelListVisibility": "labelHide"])
        XCTAssertEqual(remote.patches[1].1.body as NSDictionary, ["messageListVisibility": "hide"])
    }

    func testVisibilityIsPutBackWhenGmailRefuses() async throws {
        var labels = rows
        labels[6].listVisibility = "labelShowIfUnread"
        let q = try makeDB(labels)
        let remote = FakeRemote()
        remote.failPatch = { _, _, _ in Refused() }
        var seenWhileSaving: String?
        do {
            try await LabelVisibilityEdit.apply(
                GmailLabelPatch(labelListVisibility: .hide), rowId: id("L7"), db: q,
                didStore: { seenWhileSaving = try? self.stored(q)[self.id("L7")]?.listVisibility },
                remote: remote)
            XCTFail("must throw")
        } catch {
            XCTAssertTrue(error is Refused)
        }
        XCTAssertEqual(seenWhileSaving, "labelHide", "shown at once")
        let after = try XCTUnwrap(try stored(q)[id("L7")])
        XCTAssertEqual(after.listVisibility, "labelShowIfUnread")
        XCTAssertNil(after.messageListVisibility, "the other setting is not touched")
    }

    func testMessageListVisibilityReadsGmailsDefault() {
        XCTAssertEqual(MessageListVisibility(raw: nil), .show)
        XCTAssertEqual(MessageListVisibility(raw: "bogus"), .show)
        XCTAssertEqual(MessageListVisibility(raw: "hide"), .hide)
        XCTAssertTrue(row("L1", "x").showsInMessageList)
    }

    func testLabelSyncStoresMessageListVisibility() throws {
        let q = try makeDB([])
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: self.a, labels: [
                GLabel(id: "Label_1", name: "shown", type: "user", color: nil,
                       messageListVisibility: "show"),
                GLabel(id: "Label_2", name: "hidden", type: "user", color: nil,
                       messageListVisibility: "hide"),
            ])
        }
        let after = try stored(q)
        XCTAssertEqual(after[id("Label_1")]?.messageListVisibility, "show")
        XCTAssertEqual(after[id("Label_2")]?.messageListVisibility, "hide")
        let json = Data("""
            {"labels":[{"id":"Label_1","name":"x","type":"user","messageListVisibility":"hide"}]}
            """.utf8)
        let list = try JSONDecoder().decode(GLabelList.self, from: json)
        XCTAssertEqual(list.labels?.first?.messageListVisibility, "hide")
    }

    func testPatchBodySendsOnlyWhatChanges() {
        XCTAssertEqual(GmailLabelPatch(name: "a/b").body as NSDictionary, ["name": "a/b"])
        XCTAssertEqual(GmailLabelPatch().body as NSDictionary, [:])
        XCTAssertEqual(GmailClient.quotaCost(method: "DELETE", path: "/labels/Label_1"), 5)
    }
}

/// v66 registers last, after v65; a database that already ran every other
/// migration must still get it.
final class LabelMessageListMigrationOrderTests: XCTestCase {
    func testV66RunsOnADatabaseThatAlreadyHasTheOthers() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try db.alter(table: "label") { t in t.drop(column: "messageListVisibility") }
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v66'")
        }
        try q.read { db in
            let applied = try AppDatabase.migrator.appliedIdentifiers(db)
            XCTAssertTrue(applied.contains("v65"))
            XCTAssertFalse(applied.contains("v66"))
        }
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            XCTAssertTrue(try AppDatabase.migrator.appliedIdentifiers(db).contains("v66"))
            XCTAssertTrue(try db.columns(in: "label").contains { $0.name == "messageListVisibility" })
            XCTAssertTrue(try AppDatabase.migrator.hasCompletedMigrations(db))
        }
    }

    func testV66IsRegisteredLast() {
        XCTAssertEqual(AppDatabase.migrator.migrations.last, "v66")
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func add(_ id: String) { lock.withLock { ids.append(id) } }
    var all: [String] { lock.withLock { ids } }
}

private final class Gauge: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private var max = 0
    func enter() { lock.withLock { now += 1; max = Swift.max(max, now) } }
    func leave() { lock.withLock { now -= 1 } }
    var peak: Int { lock.withLock { max } }
}
