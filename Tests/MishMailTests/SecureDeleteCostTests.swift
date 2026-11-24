import XCTest
import GRDB

/// What overwriting deleted content costs on a realistic delete: pruning
/// 2,000 of 3,000 messages (bodies, full-text rows) from a raw-keyed
/// SQLCipher file, as `SyncEngine.pruneLocalMail` does. Each configuration
/// runs on a fresh copy of the same file; the median of three runs goes to
/// the log as `SECURE-DELETE-COST` lines. Nothing here asserts a time, so a
/// slow runner cannot fail it; it asserts only that each run deleted what it
/// should.
final class SecureDeleteCostTests: XCTestCase {
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
            _ = try AppDatabase.foldAndTruncateLog(db, freePageLimit: nil)
        }
        try pool.close()
    }

    private struct Sample {
        var prune: Double
        var scrub: Double
    }

    private func run(template: String, pragma: Bool, searchIndex: Bool, index: Int) throws -> Sample {
        let path = dir.appendingPathComponent("run-\(pragma)-\(searchIndex)-\(index).sqlite").path
        try FileManager.default.copyItem(atPath: template, toPath: path)
        let pool = try AppDatabase.openAndMigrate(path: path, key: key, scheme: .raw)
        defer { try? pool.close() }
        try pool.writeWithoutTransaction { db in
            // On the writer, which is the connection the prune runs on.
            try db.execute(sql: "PRAGMA secure_delete = \(pragma ? "ON" : "OFF")")
            try db.execute(sql: "INSERT INTO message_fts(message_fts, rank) VALUES('secure-delete', ?)",
                           arguments: [searchIndex ? 1 : 0])
            _ = try AppDatabase.foldAndTruncateLog(db, freePageLimit: nil)
        }
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        let start = Date()
        try pool.write { db in
            try SyncEngine.pruneMessages(db, accountId: account, olderThan: cutoff)
        }
        let prune = Date().timeIntervalSince(start)
        let scrubStart = Date()
        _ = try pool.writeWithoutTransaction { db in
            try AppDatabase.foldAndTruncateLog(db, freePageLimit: AppDatabase.freePagesPerCheckpoint)
        }
        let scrub = Date().timeIntervalSince(scrubStart)
        XCTAssertEqual(try pool.read { db in try Message.fetchCount(db) }, total - pruned)
        XCTAssertEqual(try pool.read { db in try MessageBody.fetchCount(db) }, total - pruned)
        return Sample(prune: prune * 1_000, scrub: scrub * 1_000)
    }

    func testCostOfOverwritingDeletedContent() throws {
        let template = dir.appendingPathComponent("template.sqlite").path
        try makeTemplate(at: template)
        let size = (try FileManager.default.attributesOfItem(atPath: template)[.size] as? NSNumber)?
            .intValue ?? 0
        print("SECURE-DELETE-COST file=\(size / 1024) KiB messages=\(total) pruned=\(pruned)")

        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let configurations: [(String, Bool, Bool)] = [
            ("pragma=off fts=off", false, false),
            ("pragma=on  fts=off", true, false),
            ("pragma=off fts=on ", false, true),
            ("pragma=on  fts=on ", true, true),
        ]
        for (label, pragma, searchIndex) in configurations {
            var samples: [Sample] = []
            for index in 0..<3 {
                samples.append(try run(template: template, pragma: pragma,
                                       searchIndex: searchIndex, index: index))
            }
            let prune = median(samples.map(\.prune))
            let scrub = median(samples.map(\.scrub))
            print(String(format: "SECURE-DELETE-COST %@ prune_ms=%.1f scrub_ms=%.1f runs=%@",
                         label, prune, scrub,
                         samples.map { String(format: "%.0f", $0.prune) }.joined(separator: "/")))
        }
    }
}
