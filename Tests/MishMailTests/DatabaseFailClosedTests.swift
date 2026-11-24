import XCTest
import GRDB

/// A legacy plaintext cache whose encryption is deferred this launch (the
/// conversion is busy, or another instance holds the file) must fail closed:
/// the app opens it read-only, so no new mail is ever written unencrypted,
/// and the next successful conversion leaves a file that cannot be read
/// without the key (F-02).
final class DatabaseFailClosedTests: XCTestCase {
    private let key = String(repeating: "ab", count: 32)
    private let fixtureMarker = "fixture-mail-body"
    private var dir: URL!
    private var path: String { dir.appendingPathComponent("mail.sqlite").path }
    private var raw: String { AppDatabase.rawKeyLiteral(key) }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mishmail-failclosed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Helpers

    private func configuration(keyString: String?) -> Configuration {
        var config = Configuration()
        if let keyString {
            config.prepareDatabase { db in try db.usePassphrase(keyString) }
        }
        return config
    }

    /// A migrated WAL database holding a private fixture table of mail-like
    /// rows, keyed as `keyString` says. nil (the default) is the plaintext
    /// file a pre-encryption build left behind.
    private func makeDatabase(keyString: String? = nil) throws {
        let pool = try DatabasePool(path: path, configuration: configuration(keyString: keyString))
        try AppDatabase.migrator.migrate(pool)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE failClosedProbe (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
            for i in 0..<20 {
                try db.execute(sql: "INSERT INTO failClosedProbe (body) VALUES (?)",
                               arguments: ["\(fixtureMarker) \(i)"])
            }
        }
        try pool.close()
    }

    private func probeCount(_ reader: some DatabaseReader) throws -> Int {
        try reader.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM failClosedProbe") ?? 0
        }
    }

    /// Every way new mail would reach the file must be refused by SQLite
    /// itself, not by a caller remembering to check a flag.
    private func assertWritesRefused(_ pool: DatabasePool, file: StaticString = #filePath, line: UInt = #line) {
        let attempts: [(String, (Database) throws -> Void)] = [
            ("insert", { db in
                try db.execute(sql: "INSERT INTO failClosedProbe (body) VALUES ('new mail')")
            }),
            ("update", { db in
                try db.execute(sql: "UPDATE failClosedProbe SET body = 'edited'")
            }),
            ("create table", { db in
                try db.execute(sql: "CREATE TABLE leaked (body TEXT)")
            }),
        ]
        for (name, attempt) in attempts {
            XCTAssertThrowsError(try pool.write(attempt), "\(name) must be refused",
                                 file: file, line: line) { error in
                XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_READONLY,
                               "\(name): \(error)", file: file, line: line)
            }
        }
    }

    /// After a successful conversion: SQLCipher header (no plaintext magic),
    /// a clean quick_check, the fixture intact under the raw key, and nothing
    /// readable without it — neither the schema nor the bytes on disk.
    private func assertEncryptedAndIntact(expectedRows: Int,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(AppDatabase.isPlaintext(path), "header must not be plaintext", file: file, line: line)

        let keyed = try DatabaseQueue(path: path, configuration: configuration(keyString: raw))
        try keyed.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok", file: file, line: line)
        }
        XCTAssertEqual(try probeCount(keyed), expectedRows, file: file, line: line)
        try keyed.close()

        // GRDB reads the schema while opening, so the unkeyed open itself
        // is what must fail (SQLITE_NOTADB).
        XCTAssertThrowsError(try {
            let unkeyed = try DatabaseQueue(path: path)
            defer { try? unkeyed.close() }
            _ = try unkeyed.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master") }
        }(), "schema must not be readable without the key", file: file, line: line) { error in
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_NOTADB, "\(error)",
                           file: file, line: line)
        }

        let fm = FileManager.default
        let marker = Data(fixtureMarker.utf8)
        for suffix in ["", "-wal"] where fm.fileExists(atPath: path + suffix) {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path + suffix))
            XCTAssertNil(bytes.range(of: marker), "mail text readable in mail.sqlite\(suffix)",
                         file: file, line: line)
        }
    }

    // MARK: Tests

    /// Another instance (here: another connection) pins the WAL, so the
    /// one-time encryption reports busy and is deferred.
    func testBusyPlaintextConversionOpensReadOnlyAndRefusesWrites() throws {
        try makeDatabase()
        let other = try DatabasePool(path: path)
        let scheme = try other.read { _ in
            try AppDatabase.prepareDatabaseFile(path: path, key: key)
        }
        XCTAssertEqual(scheme, .plaintext)
        XCTAssertTrue(AppDatabase.isPlaintext(path), "deferred: the file is left as it was")

        let pool = try AppDatabase.openAndMigrate(path: path, key: key, scheme: scheme)
        XCTAssertEqual(try probeCount(pool), 20, "existing mail stays readable")
        assertWritesRefused(pool)
        try pool.close()
        XCTAssertEqual(try probeCount(other), 20, "nothing was written to the plaintext file")
        try other.close()

        // The other instance is gone: the next launch converts.
        XCTAssertEqual(try AppDatabase.prepareDatabaseFile(path: path, key: key), .raw)
        try assertEncryptedAndIntact(expectedRows: 20)
    }

    /// Conversion disabled outright (`allowConversion: false`, as when
    /// another MishMail process is running).
    func testDisabledPlaintextConversionOpensReadOnlyAndRefusesWrites() throws {
        try makeDatabase()
        let scheme = try AppDatabase.prepareDatabaseFile(path: path, key: key, allowConversion: false)
        XCTAssertEqual(scheme, .plaintext)

        let pool = try AppDatabase.openAndMigrate(path: path, key: key, scheme: scheme)
        XCTAssertEqual(try probeCount(pool), 20, "existing mail stays readable")
        assertWritesRefused(pool)
        try pool.close()

        XCTAssertTrue(AppDatabase.isPlaintext(path))
        let check = try DatabaseQueue(path: path)
        XCTAssertEqual(try probeCount(check), 20, "nothing was written to the plaintext file")
        try check.close()

        XCTAssertEqual(try AppDatabase.prepareDatabaseFile(path: path, key: key), .raw)
        try assertEncryptedAndIntact(expectedRows: 20)
    }

    func testOnlyEncryptedSchemesAllowWrites() {
        XCTAssertTrue(AppDatabase.KeyScheme.raw.allowsWrites)
        XCTAssertTrue(AppDatabase.KeyScheme.passphrase.allowsWrites)
        XCTAssertFalse(AppDatabase.KeyScheme.plaintext.allowsWrites)
        XCTAssertNil(AppDatabase.KeyScheme.plaintext.keyString(for: key))
    }

    /// Fail-closed must not touch encrypted files: both keyed schemes still
    /// open writable and migrated.
    func testEncryptedSchemesStayWritable() throws {
        for (scheme, keyString) in [(AppDatabase.KeyScheme.raw, raw), (.passphrase, key)] {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try makeDatabase(keyString: keyString)

            let pool = try AppDatabase.openAndMigrate(path: path, key: key, scheme: scheme)
            try pool.write { db in
                try db.execute(sql: "INSERT INTO failClosedProbe (body) VALUES ('new mail')")
            }
            XCTAssertEqual(try probeCount(pool), 21, "\(scheme)")
            XCTAssertTrue(try pool.read { db in
                try AppDatabase.migrator.hasCompletedMigrations(db)
            }, "\(scheme)")
            try pool.close()
            XCTAssertFalse(AppDatabase.isPlaintext(path), "\(scheme)")
        }
    }
}
