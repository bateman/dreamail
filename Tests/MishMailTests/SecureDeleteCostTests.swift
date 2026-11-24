import XCTest
import GRDB

/// What overwriting deleted content costs on realistic deletes from a
/// raw-keyed SQLCipher file of 3,000 messages (bodies, full-text rows):
/// a prune of 2,000, as `SyncEngine.pruneLocalMail` does, and a sync-sized
/// batch of 20, each with the protections off, on per row, and on as
/// shipped (`SearchIndexDeletes` picks the bulk path). Each configuration
/// runs on a fresh copy of the same file; the median of three runs goes to
/// the log as `SECURE-DELETE-COST` lines. Nothing here asserts a time, so a
/// slow runner cannot fail it; it asserts only that each run deleted what it
/// should.
///
/// They take several seconds, so they run only on request:
/// `TEST_RUNNER_MISHMAIL_BENCHMARK=1 make test` (xcodebuild hands variables
/// prefixed `TEST_RUNNER_` to the tests). Otherwise each returns at once.
final class SecureDeleteCostTests: XCTestCase {
    private var benchmarking: Bool {
        ProcessInfo.processInfo.environment["MISHMAIL_BENCHMARK"] == "1"
    }

    private let key = String(repeating: "ef", count: 32)
    private let account = "bench@example.com"
    private let total = 3_000
    private let pruned = 2_000
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mishmail-securedelete-cost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private static let words = [
        "invoice", "meeting", "budget", "review", "travel", "schedule", "project", "draft",
        "contract", "report", "update", "proposal", "quarter", "team", "launch", "agenda",
    ]

    /// A mailbox where `pruned` messages are older than 90 days.
    private func makeTemplate(at path: String) throws {
        XCTAssertEqual(try AppDatabase.prepareDatabaseFile(path: path, key: key), .raw)
        let pool = try AppDatabase.openAndMigrate(path: path, key: key, scheme: .raw)
        try pool.write { db in
            try Account(id: account, displayName: "Bench", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
            var rng = SystemRandomNumberGenerator()
            for i in 0..<total {
                let old = i < pruned
                let id = "\(account):m\(i)"
                let subjectWords = (0..<6).map { _ in Self.words.randomElement(using: &rng)! }
                try Message(
                    id: id, accountId: account, gmailId: "m\(i)",
                    threadId: "\(account):t\(i / 3)",
                    fromHeader: "Person \(i % 97) <person\(i % 97)@example.com>",
                    toHeader: account, ccHeader: i % 5 == 0 ? "team@example.com" : "",
                    subject: subjectWords.joined(separator: " ") + " \(i)",
                    date: Date().addingTimeInterval(-Double(old ? 200 : 10) * 86_400),
                    snippet: "Snippet \(i)", bodyText: "", bodyHTML: nil,
                    messageIdHeader: "<m\(i)@example.com>", referencesHeader: "",
                    labelIds: "INBOX", isUnread: false, hasAttachment: false).insert(db)
                let paragraph = (0..<60).map { _ in Self.words.randomElement(using: &rng)! }
                    .joined(separator: " ")
                try MessageBody(messageId: id,
                                bodyText: String(repeating: paragraph + "\n", count: 4),
                                bodyHTML: "<div>" + String(repeating: "<p>\(paragraph)</p>", count: 4) + "</div>")
                    .insert(db)
            }
        }
        try pool.writeWithoutTransaction { db in
            _ = try AppDatabase.foldAndTruncateLog(db, freePageLimit: AppDatabase.freePagesPerCheckpoint)
        }
        try pool.close()
    }

    private struct Sample {
        var delete: Double
        var scrub: Double
    }

    /// How a run deletes and what it measures.
    private struct Scenario {
        var label: String
        var pragma: Bool
        var searchIndex: Bool
        /// Delete through the app's own entry point (bulk path above the
        /// threshold) rather than one plain DELETE.
        var appPath: Bool
        /// Messages deleted: the prune (2,000) or a sync-sized batch.
        var messages: Int
    }

    private func run(template: String, _ config: Scenario, index: Int) throws -> Sample {
        let path = dir.appendingPathComponent("run-\(UUID().uuidString)-\(index).sqlite").path
        try FileManager.default.copyItem(atPath: template, toPath: path)
        let pool = try AppDatabase.openAndMigrate(path: path, key: key, scheme: .raw)
        defer { try? pool.close() }
        try pool.writeWithoutTransaction { db in
            // On the writer, which is the connection the delete runs on.
            try db.execute(sql: "PRAGMA secure_delete = \(config.pragma ? "ON" : "OFF")")
            try db.execute(sql: "INSERT INTO message_fts(message_fts, rank) VALUES('secure-delete', ?)",
                           arguments: [config.searchIndex ? 1 : 0])
            _ = try AppDatabase.foldAndTruncateLog(db, freePageLimit: AppDatabase.freePagesPerCheckpoint)
        }
        let ids = (0..<config.messages).map { "\(account):m\($0)" }
        let start = Date()
        try pool.write { db in
            if config.appPath {
                _ = try SyncEngine.deleteMessages(db, localIds: ids)
            } else {
                for chunk in stride(from: 0, to: ids.count, by: 500) {
                    let part = Array(ids[chunk..<min(chunk + 500, ids.count)])
                    let marks = Array(repeating: "?", count: part.count).joined(separator: ",")
                    try db.execute(sql: "DELETE FROM message WHERE id IN (\(marks))",
                                   arguments: StatementArguments(part))
                }
            }
        }
        let delete = Date().timeIntervalSince(start)
        let scrubStart = Date()
        _ = try pool.writeWithoutTransaction { db in
            try AppDatabase.foldAndTruncateLog(db, freePageLimit: AppDatabase.freePagesPerCheckpoint)
        }
        let scrub = Date().timeIntervalSince(scrubStart)
        XCTAssertEqual(try pool.read { db in try Message.fetchCount(db) }, total - config.messages)
        XCTAssertEqual(try pool.read { db in try MessageBody.fetchCount(db) }, total - config.messages)
        return Sample(delete: delete * 1_000, scrub: scrub * 1_000)
    }

    func testCostOfOverwritingDeletedContent() throws {
        guard benchmarking else { return }
        let template = dir.appendingPathComponent("template.sqlite").path
        try makeTemplate(at: template)
        let size = (try FileManager.default.attributesOfItem(atPath: template)[.size] as? NSNumber)?
            .intValue ?? 0
        print("SECURE-DELETE-COST file=\(size / 1024) KiB messages=\(total)")

        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let sync = 20
        let configurations = [
            Scenario(label: "prune baseline (pragma off, fts per-row off)",
                          pragma: false, searchIndex: false, appPath: false, messages: pruned),
            Scenario(label: "prune pragma on",
                          pragma: true, searchIndex: false, appPath: false, messages: pruned),
            Scenario(label: "prune pragma on + fts secure-delete per row",
                          pragma: true, searchIndex: true, appPath: false, messages: pruned),
            Scenario(label: "prune as shipped (pragma on, bulk: fts rebuild)",
                          pragma: true, searchIndex: true, appPath: true, messages: pruned),
            Scenario(label: "sync batch baseline",
                          pragma: false, searchIndex: false, appPath: false, messages: sync),
            Scenario(label: "sync batch as shipped (pragma on, fts per row)",
                          pragma: true, searchIndex: true, appPath: true, messages: sync),
        ]
        for config in configurations {
            var samples: [Sample] = []
            for index in 0..<3 {
                samples.append(try run(template: template, config, index: index))
            }
            print(String(format: "SECURE-DELETE-COST %@ deleted=%ld delete_ms=%.1f scrub_ms=%.1f runs=%@",
                         config.label, config.messages,
                         median(samples.map(\.delete)), median(samples.map(\.scrub)),
                         samples.map { String(format: "%.0f", $0.delete) }.joined(separator: "/")))
        }
    }

    // MARK: At mailbox scale

    /// The two costs the bulk path weighs, at a realistic size: deleting one
    /// message securely from the index, and reindexing one remaining message
    /// in a rebuild. Their ratio is `SearchIndexDeletes.rebuildCostRatio`.
    func testBulkPathCostRatioAtMailboxScale() throws {
        guard benchmarking else { return }
        let size = 50_000
        let deleted = 500
        let path = dir.appendingPathComponent("large.sqlite").path
        XCTAssertEqual(try AppDatabase.prepareDatabaseFile(path: path, key: key), .raw)
        let pool = try AppDatabase.openAndMigrate(path: path, key: key, scheme: .raw)
        defer { try? pool.close() }
        try pool.write { db in
            try Account(id: account, displayName: "Bench", historyId: nil,
                        lastSyncAt: nil, senderName: "").insert(db)
            var rng = SystemRandomNumberGenerator()
            for i in 0..<size {
                let subject = (0..<6).map { _ in Self.words.randomElement(using: &rng)! }
                    .joined(separator: " ")
                try Message(
                    id: "\(account):m\(i)", accountId: account, gmailId: "m\(i)",
                    threadId: "\(account):t\(i / 3)",
                    fromHeader: "Person \(i % 997) <person\(i % 997)@example.com>",
                    toHeader: account, ccHeader: i % 5 == 0 ? "team@example.com" : "",
                    subject: subject + " \(i)", date: Date(), snippet: "", bodyText: "",
                    bodyHTML: nil, messageIdHeader: "<m\(i)@example.com>", referencesHeader: "",
                    labelIds: "INBOX", isUnread: false, hasAttachment: false).insert(db)
            }
        }
        try pool.writeWithoutTransaction { db in
            _ = try AppDatabase.foldAndTruncateLog(db, freePageLimit: AppDatabase.freePagesPerCheckpoint)
        }
        let ids = (0..<deleted).map { "\(account):m\($0 * (size / deleted))" }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var start = Date()
        try pool.write { db in
            try db.execute(sql: "DELETE FROM message WHERE id IN (\(marks))",
                           arguments: StatementArguments(ids))
        }
        let perRow = Date().timeIntervalSince(start) * 1_000 / Double(deleted)
        start = Date()
        try pool.write { db in
            try db.execute(sql: "INSERT INTO message_fts(message_fts) VALUES('rebuild')")
        }
        let perRebuilt = Date().timeIntervalSince(start) * 1_000 / Double(size - deleted)
        print(String(format: """
            SECURE-DELETE-COST scale=%ld secure_delete_ms_per_deleted=%.4f \
            rebuild_ms_per_remaining=%.4f ratio=%.1f
            """, size, perRow, perRebuilt, perRow / perRebuilt))
        XCTAssertEqual(try pool.read { db in try Message.fetchCount(db) }, size - deleted)
    }
}
