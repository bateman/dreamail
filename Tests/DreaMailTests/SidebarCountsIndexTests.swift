import XCTest
import GRDB

/// Pins SidebarCounts COUNT predicates to *indexed* plans (not full-table
/// SCAN). SQLite may pick a v18 composite over a v21 partial when both apply
/// (e.g. starred → `thread_on_isStarred_inTrash_lastDate`); that still
/// satisfies the goal. v21/v22 partial *existence* is asserted in
/// DatabaseMigrationTests; reminder/snoozed partials are the ones the
/// planner actually needs (no competing composite).
final class SidebarCountsIndexTests: XCTestCase {

    private func explainDetail(_ db: Database, sql: String,
                               arguments: StatementArguments = StatementArguments()) throws -> String {
        let rows = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)",
                                    arguments: arguments)
        return rows.map { "\($0["detail"] as String? ?? "")" }.joined(separator: " | ")
    }

    /// COUNT must not devolve to an unindexed full scan of `thread`.
    private func assertIndexedCount(_ db: Database, sql: String,
                                    arguments: StatementArguments = StatementArguments(),
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let detail = try explainDetail(db, sql: sql, arguments: arguments)
        // "SCAN thread" without USING INDEX = bad. SEARCH … USING INDEX = good.
        // Covering SEARCH on a partial or composite is fine.
        let unindexedScan = detail.range(
            of: #"\bSCAN\s+thread\b(?!.*USING)"#,
            options: .regularExpression) != nil
            && !detail.localizedCaseInsensitiveContains("USING INDEX")
            && !detail.localizedCaseInsensitiveContains("USING COVERING INDEX")
        XCTAssertFalse(
            unindexedScan || detail == "SCAN thread",
            "expected indexed COUNT plan, got: \(detail)",
            file: file, line: line)
        XCTAssertTrue(
            detail.localizedCaseInsensitiveContains("USING INDEX")
                || detail.localizedCaseInsensitiveContains("USING COVERING INDEX")
                || detail.localizedCaseInsensitiveContains("SEARCH"),
            "expected SEARCH/INDEX plan, got: \(detail)",
            file: file, line: line)
    }

    /// The Inbox unread / Dock badge count as the app builds it
    /// (`SidebarCounts.inboxUnreadSQL`), with no hide and with every category
    /// hidden: an index search on the Inbox key columns (inInbox, inTrash),
    /// never a scan. The v21 partial `thread_unread_primary_inbox` cannot
    /// serve it (its WHERE excludes promo/social) and is not expected.
    func testPrimaryCountPredicatesAreIndexed() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            for hide in Self.hides {
                let predicate = SidebarCounts.inboxUnreadSQL(
                    hideSQL: SidebarCounts.inboxHideSQL(hide: hide))
                try self.assertInboxKeyIndex(db, sql: """
                    SELECT COUNT(*) FROM thread WHERE (\(predicate))
                    """, arguments: [Date()], hide: hide)
                try self.assertInboxKeyIndex(db, sql: """
                    SELECT COUNT(*) FROM thread WHERE accountId = ? AND (\(predicate))
                    """, arguments: ["a@example.com", Date()], hide: hide)
            }
            try self.assertIndexedCount(db, sql: """
                SELECT COUNT(*) FROM thread
                WHERE isStarred = 1 AND inTrash = 0
                """)
            try self.assertIndexedCount(db, sql: """
                SELECT COUNT(*) FROM thread
                WHERE inDrafts = 1 AND inTrash = 0
                """)
        }
    }

    /// The per-account unread count (avatar badges) is a grouped COUNT over
    /// the same predicate (`fetchUnreadByAccount`); same index rule.
    func testUnreadByAccountIsIndexed() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            for hide in Self.hides {
                let predicate = SidebarCounts.inboxUnreadSQL(
                    hideSQL: SidebarCounts.inboxHideSQL(hide: hide))
                try self.assertInboxKeyIndex(db, sql: """
                    SELECT accountId, COUNT(*) AS n FROM thread
                    WHERE (\(predicate)) GROUP BY accountId
                    """, arguments: [Date()], hide: hide)
            }
        }
    }

    /// The per-account exemption (accounts with "Show Promotions and Social"
    /// off, one with a quote in its id) keeps the same plans.
    func testCountsWithExemptAccountsAreIndexed() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        let exempt: Set<String> = ["b@example.com", "o'brien@example.com"]
        try q.read { db in
            for hide in Self.hides {
                let predicate = SidebarCounts.inboxUnreadSQL(
                    hideSQL: SidebarCounts.inboxHideSQL(hide: hide, exempt: exempt))
                try self.assertInboxKeyIndex(db, sql: """
                    SELECT COUNT(*) FROM thread WHERE (\(predicate))
                    """, arguments: [Date()], hide: hide)
                try self.assertInboxKeyIndex(db, sql: """
                    SELECT accountId, COUNT(*) AS n FROM thread
                    WHERE (\(predicate)) GROUP BY accountId
                    """, arguments: [Date()], hide: hide)
            }
        }
    }

    private static let hides: [Set<String>] = [
        [],
        ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_UPDATES", "CATEGORY_FORUMS"],
    ]

    /// Indexed on the Inbox key (`inInbox=? AND inTrash=?`, as the
    /// v18/v32/v42 inbox composites), or on an unread partial index.
    private func assertInboxKeyIndex(_ db: Database, sql: String,
                                     arguments: StatementArguments, hide: Set<String>,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        try assertIndexedCount(db, sql: sql, arguments: arguments, file: file, line: line)
        let detail = try explainDetail(db, sql: sql, arguments: arguments)
        XCTAssertTrue(detail.contains("inInbox=? AND inTrash=?")
                        || detail.contains("thread_unread_live"),
                      "hide \(hide): expected the Inbox key or an unread partial index, got: \(detail)",
                      file: file, line: line)
        XCTAssertFalse(detail.contains("thread_unread_primary_inbox"),
                       "the v21 primary partial cannot match the new predicate: \(detail)",
                       file: file, line: line)
    }

    /// v22 partials have no v18 competitor — pin the exact index name so a
    /// predicate drift that drops the partial is caught.
    func testReminderAndSnoozedCountsUseV22Indexes() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            let rem = try self.explainDetail(db, sql: """
                SELECT COUNT(*) FROM thread
                WHERE reminderAt IS NOT NULL
                """)
            XCTAssertTrue(rem.localizedCaseInsensitiveContains("thread_has_reminder"),
                          "got: \(rem)")
            let snooze = try self.explainDetail(db, sql: """
                SELECT COUNT(*) FROM thread
                WHERE snoozeUntil IS NOT NULL AND snoozeUntil > ? AND inTrash = 0
                """, arguments: [Date()])
            XCTAssertTrue(snooze.localizedCaseInsensitiveContains("thread_snoozed_active"),
                          "got: \(snooze)")
        }
    }
}
