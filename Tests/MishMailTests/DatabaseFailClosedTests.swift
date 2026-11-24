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

    // MARK: App-level gating (AppDatabase.init)

    /// The app's own open: a deferred plaintext cache comes up `.readOnly`,
    /// its maintenance (checkpoint, vacuum) is a no-op rather than a write,
    /// and the next open with conversion allowed is writable and encrypted.
    func testAppDatabaseOpensDeferredPlaintextCacheReadOnly() throws {
        try makeDatabase()
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        let readOnly = try AppDatabase(path: path, key: key, allowConversion: false)
        XCTAssertEqual(readOnly.storageState, .readOnly)
        XCTAssertFalse(readOnly.allowsWrites)
        XCTAssertEqual(try probeCount(readOnly.dbPool), 20)
        assertWritesRefused(readOnly.dbPool)
        readOnly.checkpoint()
        readOnly.checkpoint(force: true)
        readOnly.checkpointIfNeeded()
        readOnly.reclaimSpaceIfNeeded()
        readOnly.close()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before,
                       "a read-only launch must leave the plaintext file byte-identical")

        let writable = try AppDatabase(path: path, key: key, allowConversion: true)
        XCTAssertEqual(writable.storageState, .writable)
        try writable.dbPool.write { db in
            try db.execute(sql: "INSERT INTO failClosedProbe (body) VALUES ('new mail')")
        }
        writable.close()
        try assertEncryptedAndIntact(expectedRows: 21)
    }

    /// Why `removeAccount` refuses up front: on a read-only cache the purge
    /// that follows the Keychain delete cannot run, and the account and its
    /// mail would stay on disk.
    func testAccountPurgeIsRefusedOnAReadOnlyCache() throws {
        try makeDatabase()
        let seed = try DatabaseQueue(path: path)
        try seed.write { db in
            try AccountLifecycle.accountAfterSignIn(
                email: "someone@example.com", name: "Someone", existing: nil).insert(db)
        }
        try seed.close()

        let readOnly = try AppDatabase(path: path, key: key, allowConversion: false)
        XCTAssertNotNil(readOnly.storageState.writeRefusal, "MailStore's gate refuses removal")
        XCTAssertThrowsError(try readOnly.dbPool.write { db in
            try AccountLifecycle.purgeAccount(db, id: "someone@example.com")
        })
        XCTAssertEqual(try readOnly.dbPool.read { db in try Account.fetchCount(db) }, 1)
        readOnly.close()
    }

    /// A real legacy plaintext file predates encryption, so its schema is
    /// behind this build, and it may hold WAL frames nobody checkpointed.
    /// Read-only it cannot be migrated and the current queries fail on it,
    /// so the app must not present it as a (seemingly empty) mailbox. Once
    /// converted, the WAL content is kept and migrations run on the
    /// encrypted copy.
    func testLegacySchemaBehindThisBuildBlocksTheMailboxUntilEncrypted() throws {
        // Build the legacy file elsewhere and copy it, sidecars included,
        // while its writer still holds uncheckpointed frames: what a running
        // old build leaves on disk.
        let sourcePath = dir.appendingPathComponent("legacy-source.sqlite").path
        let source = try DatabasePool(path: sourcePath)
        try AppDatabase.migrator.migrate(source, upTo: "v10")
        try source.write { db in
            try db.execute(sql: "CREATE TABLE failClosedProbe (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
            for i in 0..<20 {
                try db.execute(sql: "INSERT INTO failClosedProbe (body) VALUES (?)",
                               arguments: ["\(fixtureMarker) \(i)"])
            }
        }
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try fm.copyItem(atPath: sourcePath + suffix, toPath: path + suffix)
        }
        try source.close()
        let walSize = (try fm.attributesOfItem(atPath: path + "-wal")[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(walSize, 0, "fixture must carry uncheckpointed WAL frames")

        let blocked = try AppDatabase(path: path, key: key, allowConversion: false)
        XCTAssertEqual(blocked.storageState, .encryptionRequired)
        XCTAssertFalse(blocked.storageState.showsMailbox)
        XCTAssertNotNil(blocked.storageState.statusMessage)
        XCTAssertEqual(try probeCount(blocked.dbPool), 20, "WAL frames are visible read-only")
        // What the mailbox would hit: a column added after v10.
        XCTAssertThrowsError(try blocked.dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT deliveredTo FROM message")
        })
        XCTAssertFalse(try blocked.dbPool.read { db in
            try AppDatabase.migrator.hasCompletedMigrations(db)
        }, "migrations must not run on the plaintext file")
        assertWritesRefused(blocked.dbPool)
        blocked.close()
        XCTAssertTrue(AppDatabase.isPlaintext(path))

        let converted = try AppDatabase(path: path, key: key, allowConversion: true)
        XCTAssertEqual(converted.storageState, .writable)
        XCTAssertTrue(try converted.dbPool.read { db in
            try AppDatabase.migrator.hasCompletedMigrations(db)
        })
        converted.close()
        try assertEncryptedAndIntact(expectedRows: 20)
    }

    func testStorageStatePolicy() {
        XCTAssertTrue(AppDatabase.StorageState.writable.allowsWrites)
        XCTAssertTrue(AppDatabase.StorageState.writable.showsMailbox)
        XCTAssertNil(AppDatabase.StorageState.writable.statusMessage)
        XCTAssertNil(AppDatabase.StorageState.writable.writeRefusal)
        for state in [AppDatabase.StorageState.readOnly, .encryptionRequired] {
            XCTAssertFalse(state.allowsWrites, "\(state)")
            XCTAssertNotNil(state.statusMessage, "\(state)")
            XCTAssertNotNil(state.writeRefusal, "\(state)")
        }
        XCTAssertTrue(AppDatabase.StorageState.readOnly.showsMailbox)
        XCTAssertFalse(AppDatabase.StorageState.encryptionRequired.showsMailbox)
        // The indicator must say what is paused, not only that sync is.
        let readOnly = AppDatabase.StorageState.readOnly.statusMessage ?? ""
        for word in ["sync", "scheduled sends", "queued edits"] {
            XCTAssertTrue(readOnly.contains(word), word)
        }
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
