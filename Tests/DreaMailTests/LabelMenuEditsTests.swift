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

        /// What `labels.get` answers: the name Gmail has.
        var serverNames: [String: String] = [:]

        func label(id: String) async throws -> GLabel {
            GLabel(id: id, name: serverNames[id] ?? "", type: "user", color: nil)
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

    /// A Gmail color on a parent is what the whole family shows; the stored
    /// Mac-only colors are ignored and left as they are.
    func testGmailColorOnAParentIsWhatTheWholeFamilyShows() async throws {
        var labels = rows
        labels[0].color = "#EB5757"   // the parent
        labels[2].color = "#27AE60"   // a sublabel
        labels[4].color = "#2D9CDB"   // the look-alike
        let q = try makeDB(labels)
        let family = LabelFamily.members(of: labels[0], in: labels).map(\.id)
        let result = await GmailLabelColorEdit.applyMany(
            blue, labelRowIds: family, db: q,
            pending: PendingLabelColorEdits()) { id, color in
                self.answer(id, color)
            }
        XCTAssertTrue(result.failed.isEmpty)
        let after = try stored(q)
        for rowId in family {
            XCTAssertEqual(after[rowId]?.displayColors.background, "#4a86e8", rowId)
        }
        XCTAssertEqual(after[id("L1")]?.color, "#EB5757", "the stored value is kept")
        XCTAssertEqual(after[id("L3")]?.color, "#27AE60", "the stored value is kept")
        XCTAssertEqual(after[id("L5")]?.color, "#2D9CDB", "the look-alike is not touched")
        XCTAssertEqual(after[id("L5")]?.displayColors, .none, "the look-alike is not recoloured")
    }

    /// "Remove color" on a parent: no color on the parent and its
    /// sublabels, whatever Mac-only value is stored.
    func testRemoveColorOnAParentLeavesNoColor() async throws {
        var labels = rows
        labels[0].color = "#EB5757"
        labels[1].gmailBackgroundColor = "#4a86e8"
        labels[1].gmailTextColor = "#ffffff"
        labels[3].color = "#27AE60"
        let q = try makeDB(labels)
        let family = LabelFamily.members(of: labels[0], in: labels).map(\.id)
        let result = await GmailLabelColorEdit.applyMany(
            nil, labelRowIds: family, db: q,
            pending: PendingLabelColorEdits()) { id, _ in
                self.answer(id, nil)
            }
        XCTAssertTrue(result.failed.isEmpty)
        let after = try stored(q)
        for rowId in family { XCTAssertEqual(after[rowId]?.displayColors, LabelColors.none, rowId) }
    }

    /// A failed sublabel keeps its old Gmail color; its stored Mac-only
    /// value is not touched either way.
    func testCascadeFailureKeepsTheOldGmailColor() async throws {
        var labels = rows
        labels[2].color = "#27AE60"
        labels[2].gmailBackgroundColor = "#fad165"
        labels[2].gmailTextColor = "#000000"
        let q = try makeDB(labels)
        let family = LabelFamily.members(of: labels[0], in: labels).map(\.id)
        let result = await GmailLabelColorEdit.applyMany(
            blue, labelRowIds: family, db: q,
            pending: PendingLabelColorEdits()) { id, color in
                if id == "L3" { throw GmailError.http(400, "bad") }
                return self.answer(id, color)
            }
        XCTAssertEqual(result.failed, [id("L3")])
        XCTAssertEqual(result.permanent, [id("L3")], "a 400 is not offered for retry")
        XCTAssertTrue(result.retryable.isEmpty)
        XCTAssertEqual(try stored(q)[id("L3")]?.displayColors,
                       LabelColors(background: "#fad165", text: "#000000"))
        XCTAssertEqual(try stored(q)[id("L3")]?.color, "#27AE60")
    }

    func testCascadeSaysWhenTheReasonsDiffer() async throws {
        let q = try makeDB()
        let family = LabelFamily.members(of: rows[0], in: rows).map(\.id)
        let result = await GmailLabelColorEdit.applyMany(
            blue, labelRowIds: family, db: q, pending: PendingLabelColorEdits()) { id, color in
                if id == "L2" { throw URLError(.timedOut) }
                if id == "L4" { throw GmailError.http(500, "") }
                return self.answer(id, color)
            }
        XCTAssertEqual(result.failed, [id("L2"), id("L4")])
        XCTAssertTrue(result.mixedCauses)
        XCTAssertEqual(result.retryable, [id("L2"), id("L4")])
    }

    /// A cascade never writes the Mac-only column.
    func testCascadeNeverWritesTheMacOnlyColor() async throws {
        var labels = rows
        labels[1].color = "#EB5757"
        labels[2].color = "#27AE60"
        let q = try makeDB(labels)
        let family = LabelFamily.members(of: labels[0], in: labels).map(\.id)
        _ = await GmailLabelColorEdit.applyMany(
            blue, labelRowIds: family, db: q, pending: PendingLabelColorEdits()) { id, color in
                self.answer(id, color)
            }
        let after = try stored(q)
        XCTAssertEqual(after[id("L2")]?.color, "#EB5757")
        XCTAssertEqual(after[id("L3")]?.color, "#27AE60")
        XCTAssertNil(after[id("L1")]?.color)
        XCTAssertNil(after[id("L5")]?.color)
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

    /// Gmail answers "name exists" for a sublabel that already has the
    /// target name (its parent's rename carried it along): that is success,
    /// not a reason to roll the whole rename back.
    func testNameConflictOnALabelThatAlreadyHasTheNameIsSuccess() async throws {
        let remote = FakeRemote()
        remote.serverNames = ["L2": "Calls/PRIN", "L3": "Bandi/PRIN/2025"]
        // Only the forward renames conflict; putting names back works.
        remote.failPatch = { id, patch, _ in
            (id == "L2" || id == "L3") && patch.name?.hasPrefix("Calls") == true
                ? GmailError.http(409, "Label name exists or conflicts") : nil
        }
        let changes = try LabelRename.plan(label: rows[0], name: "Calls", parent: nil, rows: rows).get()
        let (outcome, _) = await LabelRename.execute(changes, remote: remote)
        // L2 already has its new name; L3 does not, so the rename is undone.
        guard case .rolledBack(let cause) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(LabelRename.isNameConflict(cause))
        let undone = Set(remote.patches.filter { $0.1.name?.hasPrefix("Bandi") == true }.map(\.0))
        XCTAssertTrue(undone.contains("L2"), "L2 counted as renamed, so it is put back too")

        let again = FakeRemote()
        again.serverNames = ["L2": "Calls/PRIN", "L3": "Calls/PRIN/2025"]
        again.failPatch = { id, _, _ in
            id == "L2" || id == "L3" ? GmailError.http(409, "Label name exists or conflicts") : nil
        }
        let (second, names) = await LabelRename.execute(changes, remote: again)
        guard case .renamed = second else { return XCTFail("\(second)") }
        XCTAssertEqual(names[id("L3")], "Calls/PRIN/2025")
    }

    func testLabelWritesRetryARateLimitOnce() {
        XCTAssertEqual(GmailClient.rateLimitAttempts(method: "PATCH", path: "/labels/Label_1"), 2)
        XCTAssertEqual(GmailClient.rateLimitAttempts(method: "DELETE", path: "/labels/Label_1"), 2)
        XCTAssertEqual(GmailClient.rateLimitAttempts(method: "GET", path: "/labels"),
                       GmailClient.requestRetryAttempts)
        XCTAssertEqual(GmailClient.rateLimitAttempts(method: "POST", path: "/messages/send"), 0)
        XCTAssertEqual(GmailClient.rateLimitAttempts(method: "POST", path: "/labels"), 0)
    }

    /// `A` → `A/B` while `A/B` exists: `A/B` moves first, or Gmail would
    /// refuse `A`'s new name.
    func testRenameIntoItsOwnFamilyGoesDeepestFirst() async throws {
        let labels = [row("A", "A"), row("B", "A/B")]
        let changes = try LabelRename.plan(label: labels[0], name: "B", parent: nil, rows: labels).get()
        XCTAssertEqual(changes.map(\.to), ["B", "B/B"])
        let into = try LabelRename.plan(label: labels[0], name: "A/B", parent: nil, rows: labels).get()
        XCTAssertEqual(into.map(\.to), ["A/B", "A/B/B"])
        let waves = LabelRename.waves(into.map { (from: $0.from, to: $0.to) })
        XCTAssertEqual(waves, [[1], [0]])

        // A remote that refuses a name another label holds, ignoring case.
        let held = Names(["A": "A", "B": "A/B"])
        let remote = FakeRemote()
        remote.failPatch = { id, patch, _ in
            guard let name = patch.name else { return nil }
            return held.take(id, name) ? nil : GmailError.http(409, "Label name exists or conflicts")
        }
        let (outcome, names) = await LabelRename.execute(into, remote: remote)
        guard case .renamed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(names, [id("A"): "A/B", id("B"): "A/B/B"])
    }

    func testPermanentRefusalsAreNotRetried() async throws {
        let remote = FakeRemote()
        remote.failPatch = { id, _, _ in id == "L3" ? GmailError.http(400, "Invalid label name") : nil }
        let changes = try LabelRename.plan(label: rows[0], name: "Calls", parent: nil, rows: rows).get()
        _ = await LabelRename.execute(changes, remote: remote)
        let forwardL3 = remote.patches.filter { $0.0 == "L3" && $0.1.name == "Calls/PRIN/2025" }
        XCTAssertEqual(forwardL3.count, 1, "a 400 is sent once")
        XCTAssertTrue(LabelBatch.isPermanent(GmailError.http(404, "")))
        XCTAssertFalse(LabelBatch.isPermanent(GmailError.http(429, "")))
        XCTAssertFalse(LabelBatch.isPermanent(GmailError.http(503, "")))
        XCTAssertFalse(LabelBatch.isPermanent(URLError(.timedOut)))
    }

    func testRenameFollowsInFilterChipsAndSavedViews() throws {
        var chips = FilterChips()
        chips.labelId = "L2"
        chips.labelName = "Bandi/PRIN"
        let changes = try LabelRename.plan(label: rows[0], name: "Calls", parent: nil, rows: rows).get()
        for c in changes { chips.followRename(labelId: c.gmailLabelId, from: c.from, to: c.to) }
        XCTAssertEqual(chips.labelName, "Calls/PRIN")
        XCTAssertEqual(chips.labelId, "L2")

        let views = [view(1, account: a, labelId: nil, chipsLabel: "L2"), view(2, account: a, labelId: "L7")]
        var named = views
        var withName = FilterChips()
        withName.labelId = "L2"
        withName.labelName = "Bandi/PRIN"
        named[0].chipsJSON = try JSONEncoder().encode(withName)
        let updated = LabelRename.views(named, after: changes, accountId: a)
        XCTAssertTrue(LabelRename.views(named, after: changes, accountId: b).isEmpty,
                      "another account's view is not touched")
        XCTAssertEqual(updated.map(\.id), [1])
        let decoded = try JSONDecoder().decode(FilterChips.self, from: XCTUnwrap(updated.first?.chipsJSON))
        XCTAssertEqual(decoded.labelName, "Calls/PRIN")

        var dropped = chips
        dropped.labelExclude = true
        dropped.dropLabel(row("L2", "Calls/PRIN"))
        XCTAssertNil(dropped.labelId)
        XCTAssertNil(dropped.labelName)
        XCTAssertFalse(dropped.labelExclude)
        var otherAccount = chips
        otherAccount.dropLabel(row("L2", "Something else", account: b))
        XCTAssertEqual(otherAccount.labelId, "L2", "same id, another label: kept")
    }

    func testSelectionAfterRemovalAndRename() {
        let removed = LabelRemoval.order(rows[0], rows: rows)
        let open = MailboxView.label(account: a, labelId: "L3", name: "Bandi/PRIN/2025")
        XCTAssertEqual(LabelSelection.afterRemoval(open, removed: removed, views: []), .inbox)
        let otherAccount = MailboxView.label(account: b, labelId: "L1", name: "Bandi/other")
        XCTAssertNil(LabelSelection.afterRemoval(otherAccount, removed: removed, views: []))
        XCTAssertNil(LabelSelection.afterRemoval(.starred, removed: removed, views: []))
        let savedView = view(9, account: a, labelId: "L2")
        XCTAssertEqual(LabelSelection.afterRemoval(.saved(9, "v9"), removed: removed, views: [savedView]), .inbox)

        XCTAssertEqual(LabelSelection.afterRename(open, names: [id("L3"): "Calls/PRIN/2025"]),
                       .label(account: a, labelId: "L3", name: "Calls/PRIN/2025"))
        XCTAssertNil(LabelSelection.afterRename(open, names: [id("L3"): "Bandi/PRIN/2025"]))
        XCTAssertNil(LabelSelection.afterRename(otherAccount, names: [id("L1"): "x"]))
    }

    // MARK: Remove

    /// The confirmation named one label; a sync renamed it meanwhile (or
    /// removed it): Remove does nothing rather than delete what now has
    /// that id.
    func testRemovalActsOnlyOnTheLabelTheConfirmationNamed() {
        let snapshot = rows[0]
        XCTAssertEqual(LabelRemoval.resolve(snapshot, current: rows)?.id, snapshot.id)
        var renamed = rows
        renamed[0].name = "B"
        renamed.append(row("L9", "Bandi"))
        XCTAssertNil(LabelRemoval.resolve(snapshot, current: renamed), "renamed elsewhere: nothing")
        XCTAssertNil(LabelRemoval.resolve(snapshot, current: Array(rows.dropFirst())), "gone: nothing")
    }

    private func view(_ id: Int64, account: String?, labelId: String?, chipsLabel: String? = nil) -> SavedView {
        var v = SavedView.empty()
        v.id = id
        v.name = "v\(id)"
        v.accountId = account
        v.labelId = labelId
        if let chipsLabel {
            var chips = FilterChips()
            chips.labelId = chipsLabel
            v.chipsJSON = try? JSONEncoder().encode(chips)
        }
        return v
    }

    func testSavedViewsOnARemovedLabelGoWithIt() throws {
        let removed = LabelRemoval.order(rows[0], rows: rows)
        let views = [
            view(1, account: a, labelId: "L2"),                     // a sublabel: goes
            view(2, account: a, labelId: nil, chipsLabel: "L4"),    // in its chips: goes
            view(3, account: a, labelId: "L5"),                     // look-alike: stays
            view(4, account: b, labelId: "L2"),                     // other account: stays
            view(5, account: nil, labelId: "L1"),                   // all accounts, b has L1: stays
            view(6, account: nil, labelId: "L3"),                   // all accounts, only a: goes
            view(7, account: a, labelId: nil),                      // no label: stays
        ]
        let changes = LabelRemoval.views(views, removing: removed, allLabels: rows)
        XCTAssertEqual(changes.removed.compactMap(\.id), [1, 2, 6])
        XCTAssertTrue(changes.updated.isEmpty)
    }

    /// "Not label Newsletters" still works without the label: the view stays
    /// and only loses that filter.
    func testASavedViewThatOnlyExcludesTheLabelStays() throws {
        var excluding = view(1, account: a, labelId: nil, chipsLabel: "L2")
        var chips = FilterChips()
        chips.labelId = "L2"
        chips.labelName = "Bandi/PRIN"
        chips.labelExclude = true
        chips.read = .unread
        excluding.chipsJSON = try JSONEncoder().encode(chips)
        let removed = LabelRemoval.order(rows[0], rows: rows)
        let changes = LabelRemoval.views([excluding], removing: removed, allLabels: rows)
        XCTAssertTrue(changes.removed.isEmpty)
        XCTAssertEqual(changes.updated.map(\.id), [1])
        let kept = try JSONDecoder().decode(FilterChips.self, from: XCTUnwrap(changes.updated.first?.chipsJSON))
        XCTAssertNil(kept.labelId)
        XCTAssertNil(kept.labelName)
        XCTAssertFalse(kept.labelExclude)
        XCTAssertEqual(kept.read, .unread, "the rest of the view is kept")
    }

    func testRemovalForgetsSavedViewsAndUserDefaults() throws {
        let q = try makeDB()
        try q.write { db in
            var kept = self.view(0, account: self.a, labelId: "L7")
            kept.id = nil
            kept.name = "kept"
            try kept.insert(db)
            var gone = self.view(0, account: self.a, labelId: "L2")
            gone.id = nil
            gone.name = "gone"
            try gone.insert(db)
        }
        // Read back, with the ids the database gave them, as the app does.
        let saved = try q.read { try SavedView.fetchAll($0) }
        let removed = LabelRemoval.order(rows[0], rows: rows)
        let views = LabelRemoval.views(saved, removing: removed, allLabels: rows)
        XCTAssertEqual(views.removed.map(\.labelId), ["L2"])
        try q.write { db in try LabelRemoval.forget(db, rows: removed, views: views) }
        let left = try q.read { try SavedView.fetchAll($0).map(\.name) }
        XCTAssertEqual(left, ["kept"])

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LabelMenuEditsTests.\(UUID())"))
        let key = "categoryFilter.label.\(a).L2"
        let other = "categoryFilter.label.\(b).L2"
        defaults.set(Data([1]), forKey: key)
        defaults.set(Data([1]), forKey: other)
        SidebarDisclosure.setLabel("L2", accountId: a, expanded: true, defaults)
        LabelRemoval.forgetDefaults(removed, defaults)
        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertNotNil(defaults.object(forKey: other), "the other account's label keeps its filter")
        XCTAssertTrue(SidebarDisclosure.expandedLabels(accountId: a, defaults).isEmpty)
    }

    func testLabelNamesAreShownSafely() {
        XCTAssertEqual(LabelText.safe("Work"), "Work")
        XCTAssertEqual(LabelText.safe("a\u{202E}b"), "a\u{27E8}U+202E\u{27E9}b")
        XCTAssertEqual(LabelText.safe("a\u{2067}b\u{2069}"), "a\u{27E8}U+2067\u{27E9}b\u{27E8}U+2069\u{27E9}")
        XCTAssertEqual(LabelText.safe("a\nb"), "a\u{27E8}U+000A\u{27E9}b")
        XCTAssertEqual(LabelText.safe("a\u{2028}b"), "a\u{27E8}U+2028\u{27E9}b")
        // Markdown stays literal text (shown with Text(verbatim:)).
        XCTAssertEqual(LabelText.safe("[Inbox](x) *a*"), "[Inbox](x) *a*")
        XCTAssertEqual(LabelText.quoted("é/ü"), "“é/ü”")
        XCTAssertEqual(LabelText.safe("Wo\u{200B}rk"), "Wo\u{27E8}U+200B\u{27E9}rk")
        XCTAssertEqual(LabelText.safe("\u{FEFF}a\u{2060}"), "\u{27E8}U+FEFF\u{27E9}a\u{27E8}U+2060\u{27E9}")
    }

    func testRemoveConfirmationNamesTheAccountWithSeveralAccounts() {
        let label = row("L1", "Work\u{202E}")
        XCTAssertEqual(LabelRemovalText.title(label: label, multipleAccounts: false),
                       "Remove label “Work\u{27E8}U+202E\u{27E9}”?")
        XCTAssertEqual(LabelRemovalText.title(label: label, multipleAccounts: true),
                       "Remove label “Work\u{27E8}U+202E\u{27E9}” from a@x.com?")
        let text = LabelRemovalText.message(label: label, sublabels: 0, savedViews: ["Calls", "PRIN"])
        XCTAssertTrue(text.contains("The saved views “Calls”, “PRIN”, which show it, are removed too."), text)
    }

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
        let ids = try await q.read { db in
            try String.fetchAll(db, sql: "SELECT labelIds FROM thread ORDER BY id")
        }
        XCTAssertEqual(ids, ["INBOX", "INBOX L5", "INBOX L1"], "the id lists lose the removed label only")
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

/// v66 registers after v65 and before v67; a database that already ran
/// every other migration must still get it.
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

    func testV66RegistersAfterV65AndBeforeV67() throws {
        let ids = AppDatabase.migrator.migrations
        let v65 = try XCTUnwrap(ids.firstIndex(of: "v65"))
        let v66 = try XCTUnwrap(ids.firstIndex(of: "v66"))
        XCTAssertGreaterThan(v66, v65, "v66 registers after v65")
        if let v67 = ids.firstIndex(of: "v67") { XCTAssertLessThan(v66, v67, "and before v67") }
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

/// Label names on a fake Gmail: a rename takes a name only when no other
/// label holds it, ignoring case.
private final class Names: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String]
    init(_ names: [String: String]) { self.names = names }
    func take(_ id: String, _ name: String) -> Bool {
        lock.withLock {
            if names.contains(where: { $0.key != id && $0.value.caseInsensitiveCompare(name) == .orderedSame }) {
                return false
            }
            names[id] = name
            return true
        }
    }
}
