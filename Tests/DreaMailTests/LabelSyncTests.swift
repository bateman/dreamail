import XCTest
import GRDB

/// SyncEngine.applyLabels — the local label table follows Gmail's label
/// list, including labels deleted in Gmail.
final class LabelSyncTests: XCTestCase {
    private let account = "a@x.com"
    private let other = "b@x.com"

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            for id in [account, other] {
                try Account(id: id, displayName: "P", historyId: nil,
                            lastSyncAt: nil, senderName: "").save(db)
            }
        }
        return q
    }

    private func label(_ id: String, _ name: String, type: String? = "user",
                       color: String? = nil) -> GLabel {
        GLabel(id: id, name: name, type: type,
               color: color.map { GLabel.GColor(backgroundColor: $0, textColor: nil) })
    }

    private func names(_ q: DatabaseQueue, account: String) throws -> Set<String> {
        try q.read { db in
            try String.fetchSet(db, sql: "SELECT name FROM label WHERE accountId = ?",
                                arguments: [account])
        }
    }

    func testLabelDeletedInGmailIsRemovedLocally() throws {
        let q = try makeDB()
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                label("INBOX", "INBOX", type: "system"),
                label("Label_1", "Old project"),
                label("Label_2", "Receipts"),
            ])
        }
        XCTAssertEqual(try names(q, account: account), ["INBOX", "Old project", "Receipts"])

        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                label("INBOX", "INBOX", type: "system"),
                label("Label_2", "Receipts"),
            ])
        }
        XCTAssertEqual(try names(q, account: account), ["INBOX", "Receipts"])
    }

    /// A label deleted on Gmail leaves nothing behind on this Mac either
    /// ("deleted means gone"): its disclosure state goes with the row.
    func testLabelDeletedInGmailForgetsItsDefaults() throws {
        let suite = "LabelSyncTests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let q = try makeDB()
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                label("Label_1", "Old project"), label("Label_2", "Receipts"),
            ], defaults: d)
        }
        SidebarDisclosure.setLabel("Label_1", accountId: account, expanded: true, d)
        SidebarDisclosure.setLabel("Label_2", accountId: account, expanded: true, d)
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                label("Label_2", "Receipts"),
            ], defaults: d)
        }
        XCTAssertEqual(SidebarDisclosure.expandedLabels(accountId: account, d), ["Label_2"])
    }

    /// Rows as the migrations really leave them: written before v10 (no
    /// order, no color), system and category rows next to user ones, every
    /// optional column NULL. Reading them as whole `LabelRow`s (as
    /// `applyLabels` does since #100) must not throw, or every sync pass
    /// would stop before fetching mail.
    func testApplyLabelsReadsRowsWrittenBeforeLaterMigrations() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v1")
        try q.write { db in
            try db.execute(sql: "INSERT INTO account (id, displayName) VALUES (?, 'P')",
                           arguments: [account])
            for (id, type) in [("INBOX", "system"), ("UNREAD", "system"),
                               ("CATEGORY_UPDATES", "system"), ("Label_1", "user"),
                               ("Label_2", "user")] {
                try db.execute(sql: """
                    INSERT INTO label (id, accountId, gmailLabelId, name, type)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: ["\(account):\(id)", account, id, id, type])
            }
        }
        try AppDatabase.migrator.migrate(q)
        let suite = "LabelSyncTests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }

        // Label_2 was deleted in Gmail.
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                label("INBOX", "INBOX", type: "system"),
                label("UNREAD", "UNREAD", type: "system"),
                label("CATEGORY_UPDATES", "CATEGORY_UPDATES", type: "system"),
                label("Label_1", "Label_1"),
            ], defaults: d)
        }
        XCTAssertEqual(try names(q, account: account),
                       ["INBOX", "UNREAD", "CATEGORY_UPDATES", "Label_1"])
        let rows = try q.read { try LabelRow.fetchAll($0) }
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { $0.sortOrder == LabelRow.unsorted })
    }

    /// v69: a stored order that only repeats the names in code-point order is
    /// put back to unsorted, per sibling group; a hand-made order stays;
    /// running it again changes nothing.
    func testMigrationV69ResetsMachineOrderOnly() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v68")
        try q.write { db in
            try Account(id: account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            func put(_ name: String, _ order: Int) throws {
                try LabelRow(id: "\(account):\(name)", accountId: account, gmailLabelId: name,
                             name: name, type: "user", color: nil, sortOrder: order,
                             listVisibility: nil).save(db)
            }
            // Top level: code-point order (Zeta, alpha) as an old drag froze it.
            try put("Zeta", 0); try put("alpha", 1); try put("p", 2)
            // p's sublabels: arranged by hand (b before a: not code-point order).
            try put("p/b", 3); try put("p/a", 4)
        }
        func orders() throws -> [String: Int] {
            try q.read { db in
                Dictionary(uniqueKeysWithValues: try LabelRow.fetchAll(db).map { ($0.name, $0.sortOrder) })
            }
        }
        try AppDatabase.migrator.migrate(q)
        let u = LabelRow.unsorted
        XCTAssertEqual(try orders(), ["Zeta": u, "alpha": u, "p": u, "p/b": 3, "p/a": 4])
        // Idempotent: migrating again (nothing left to apply) changes nothing.
        try AppDatabase.migrator.migrate(q)
        XCTAssertEqual(try orders(), ["Zeta": u, "alpha": u, "p": u, "p/b": 3, "p/a": 4])
    }

    /// Both visibility fields follow Gmail on every sync: a change made in
    /// Gmail overwrites the stored value, and an answer without the field
    /// (Gmail's default) does not keep an older one.
    func testListAndMessageVisibilityFollowGmailOnEverySync() throws {
        let q = try makeDB()
        func sync(_ list: String?, _ message: String?) throws {
            try q.write { db in
                try SyncEngine.applyLabels(db, accountId: account, labels: [
                    GLabel(id: "Label_1", name: "Receipts", type: "user", color: nil,
                           labelListVisibility: list, messageListVisibility: message),
                ])
            }
        }
        func stored() throws -> (String?, String?) {
            let row = try q.read { db in try LabelRow.fetchOne(db, key: "\(account):Label_1") }
            return (row?.listVisibility, row?.messageListVisibility)
        }
        try sync("labelShowIfUnread", "hide")
        XCTAssertTrue(try stored() == ("labelShowIfUnread", "hide"))
        try sync("labelShow", "show")
        XCTAssertTrue(try stored() == ("labelShow", "show"), "a change made in Gmail is stored")
        try sync("labelHide", "hide")
        try sync(nil, nil)
        XCTAssertTrue(try stored() == (nil, nil), "an omitted field does not keep an older value")
        XCTAssertEqual(SidebarLabelNode.Visibility(raw: nil), .show, "and reads as Gmail's default")
    }

    func testSurvivingLabelsKeepLocalColorAndOrder() throws {
        let q = try makeDB()
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                label("Label_1", "Old project"),
                label("Label_2", "Receipts", color: "#111111"),
            ])
            try db.execute(
                sql: "UPDATE label SET color = '#ABCDEF', sortOrder = 3 WHERE gmailLabelId = 'Label_2'")
        }
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                label("Label_2", "Receipts renamed", color: "#222222"),
            ])
        }
        let rows = try q.read { db in try LabelRow.fetchAll(db) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.name, "Receipts renamed")
        XCTAssertEqual(rows.first?.color, "#ABCDEF")
        XCTAssertEqual(rows.first?.sortOrder, 3)
    }

    func testOtherAccountIsNotTouched() throws {
        let q = try makeDB()
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: other, labels: [
                label("Label_1", "Theirs"),
                label("Label_9", "Also theirs"),
            ])
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                label("Label_1", "Mine"),
            ])
        }
        // Same Gmail label id on both accounts; account A drops everything
        // but Label_2.
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                label("Label_2", "New"),
            ])
        }
        XCTAssertEqual(try names(q, account: account), ["New"])
        XCTAssertEqual(try names(q, account: other), ["Theirs", "Also theirs"])
    }

    /// An empty list is never a real Gmail answer (system labels always
    /// exist); it must not wipe the table.
    func testEmptyListDeletesNothing() throws {
        let q = try makeDB()
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                label("Label_1", "Old project"),
            ])
            try SyncEngine.applyLabels(db, accountId: account, labels: [])
        }
        XCTAssertEqual(try names(q, account: account), ["Old project"])
    }

    /// More labels than one statement binds: the delete is not an
    /// `id NOT IN (…)` over the fetched list.
    func testManyLabelsSurviveAndOnlyTheMissingOneGoes() throws {
        let q = try makeDB()
        let many = (0..<1_200).map { label("Label_\($0)", "L\($0)") }
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: many)
            try SyncEngine.applyLabels(db, accountId: account,
                                       labels: many.filter { $0.id != "Label_700" })
        }
        let ids = try q.read { db in
            try String.fetchSet(db, sql: "SELECT gmailLabelId FROM label")
        }
        XCTAssertEqual(ids.count, 1_199)
        XCTAssertFalse(ids.contains("Label_700"))
    }
}
