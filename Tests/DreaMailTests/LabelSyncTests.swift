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
        try AppDatabase.migrator.migrate(q, upTo: "v69")
        let u = LabelRow.unsorted
        XCTAssertEqual(try orders(), ["Zeta": u, "alpha": u, "p": u, "p/b": 3, "p/a": 4])
        // Idempotent: migrating again (nothing left to apply) changes nothing.
        try AppDatabase.migrator.migrate(q, upTo: "v69")
        XCTAssertEqual(try orders(), ["Zeta": u, "alpha": u, "p": u, "p/b": 3, "p/a": 4])
    }

    private func orders(_ q: DatabaseQueue) throws -> [String: Int] {
        try q.read { db in
            Dictionary(uniqueKeysWithValues: try LabelRow.fetchAll(db).map { ($0.name, $0.sortOrder) })
        }
    }

    /// v70: every stored order of a user label goes, hand-made or not; system
    /// labels are left alone; running again changes nothing; an order stored
    /// after it (a drag) is kept.
    func testMigrationV70ResetsEveryUserLabelOnce() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v69")
        try q.write { db in
            try Account(id: account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            for (name, type, order) in [("Zeta", "user", 0), ("alpha", "user", 2), ("p", "user", 1),
                                        ("p/b", "user", 3), ("p/a", "user", 4), ("INBOX", "system", 7)] {
                try LabelRow(id: "\(account):\(name)", accountId: account, gmailLabelId: name,
                             name: name, type: type, color: nil, sortOrder: order,
                             listVisibility: nil).save(db)
            }
        }
        try AppDatabase.migrator.migrate(q)
        let u = LabelRow.unsorted
        let expected = ["Zeta": u, "alpha": u, "p": u, "p/b": u, "p/a": u, "INBOX": 7]
        XCTAssertEqual(try orders(q), expected)
        try AppDatabase.migrator.migrate(q)
        XCTAssertEqual(try orders(q), expected, "idempotent")
        // A drag made afterwards is kept by later launches.
        try q.write { db in
            try LabelRow.filter(Column("id") == "\(account):p/b")
                .updateAll(db, Column("sortOrder").set(to: 0))
        }
        try AppDatabase.migrator.migrate(q)
        XCTAssertEqual(try orders(q)["p/b"], 0)
    }

    /// "Use Gmail's Order": clears the shown account's stored order only.
    func testClearStoredOrderTouchesOneAccountsUserLabels() throws {
        let q = try makeDB()
        try q.write { db in
            for (acc, name, type, order) in [(account, "x", "user", 1), (account, "y", "user", 0),
                                             (account, "INBOX", "system", 5), (other, "x", "user", 2)] {
                try LabelRow(id: "\(acc):\(name)", accountId: acc, gmailLabelId: name,
                             name: name, type: type, color: nil, sortOrder: order,
                             listVisibility: nil).save(db)
            }
            XCTAssertEqual(try LabelRow.clearStoredOrder(db, accountId: account), 2)
            XCTAssertEqual(try LabelRow.clearStoredOrder(db, accountId: account), 0, "idempotent")
        }
        let u = LabelRow.unsorted
        let all = try q.read { db in
            Dictionary(uniqueKeysWithValues: try LabelRow.fetchAll(db).map { ($0.id, $0.sortOrder) })
        }
        XCTAssertEqual(all, ["\(account):x": u, "\(account):y": u, "\(account):INBOX": 5,
                             "\(other):x": 2])
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
