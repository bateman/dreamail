import XCTest
import GRDB

/// Secret keys in memory, standing in for the Keychain.
final class MemorySecretKeys: PGPSecretKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PGPSecretKeyOwner: Data] = [:]
    var refusesDeletes = false

    var stored: [PGPSecretKeyOwner: Data] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    func secretKey(of owner: PGPSecretKeyOwner) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[owner]
    }

    func setSecretKey(_ armored: Data, of owner: PGPSecretKeyOwner) throws {
        lock.lock(); defer { lock.unlock() }
        items[owner] = armored
    }

    func deleteSecretKey(of owner: PGPSecretKeyOwner) throws {
        lock.lock(); defer { lock.unlock() }
        if refusesDeletes { throw KeychainError.status(-25308) }
        items[owner] = nil
    }

    func owners() throws -> [PGPSecretKeyOwner] {
        lock.lock(); defer { lock.unlock() }
        return Array(items.keys)
    }
}

/// The OpenPGP key store (v62): certificates per account in the encrypted
/// database, secret keys only in the Keychain, passphrases only in memory,
/// and nothing left behind when a key or an account goes (DEC-019).
final class PGPKeyStoreTests: XCTestCase {

    private let a = "a@x.com", b = "b@x.com"
    private let k1 = PGPKeyReference(fingerprint: "AAAA1111"), k2 = PGPKeyReference(fingerprint: "BBBB2222")

    /// Markers, not key material.
    private func cert(_ marker: String) -> Data { Data("CERT \(marker)\n".utf8) }
    private func secret(_ marker: String) -> Data { Data("SECRET \(marker)\n".utf8) }

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            for id in [a, b] {
                try Account(id: id, displayName: id, historyId: nil, lastSyncAt: nil, senderName: "").insert(db)
            }
        }
        return q
    }

    private func store(_ account: String, _ q: DatabaseQueue, _ secrets: MemorySecretKeys,
                       _ passphrases: PGPPassphrases = PGPPassphrases()) -> DatabasePGPKeyStore {
        DatabasePGPKeyStore(accountId: account, database: q, secrets: secrets, passphrases: passphrases)
    }

    func testMigrationCreatesATableWithNoPlaceForSecretKeys() throws {
        let q = try makeDB()
        try q.read { db in
            XCTAssertTrue(try AppDatabase.migrator.appliedIdentifiers(db).contains("v62"))
            XCTAssertEqual(try db.columns(in: "pgpKey").map(\.name),
                           ["accountId", "fingerprint", "certificate", "hasSecretKey", "addedAt"])
        }
    }

    func testKeysArePerAccountAndSecretKeysStayOutOfTheDatabase() async throws {
        let q = try makeDB()
        let secrets = MemorySecretKeys()
        let storeA = store(a, q, secrets), storeB = store(b, q, secrets)
        try await storeA.addCertificates([PGPArmoredKey(key: k2, armored: cert("2")),
                                          PGPArmoredKey(key: k1, armored: cert("1"))])
        try await storeB.addCertificates([PGPArmoredKey(key: k2, armored: cert("b2"))])
        try await storeA.addSecretKeys([PGPArmoredKey(key: k1, armored: secret("1"))])

        let certsA = try await storeA.certificates()
        let certsB = try await storeB.certificates()
        let secretsA = try await storeA.secretKeys()
        let secretsB = try await storeB.secretKeys()
        XCTAssertEqual(certsA, cert("1") + cert("2"))
        XCTAssertEqual(certsB, cert("b2"))
        XCTAssertEqual(secretsA, secret("1"))
        XCTAssertEqual(secretsB, Data())
        XCTAssertEqual(secrets.stored, [PGPSecretKeyOwner(accountId: a, key: k1): secret("1")])

        try await q.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM pgpKey")
            for row in rows {
                for column in row.columnNames {
                    let value: DatabaseValue = row[column]
                    var text = ""
                    switch value.storage {
                    case .blob(let data): text = String(decoding: data, as: UTF8.self)
                    case .string(let string): text = string
                    default: break
                    }
                    XCTAssertFalse(text.contains("SECRET"), "secret material in pgpKey.\(column)")
                }
            }
            XCTAssertEqual(try Bool.fetchOne(db, sql: """
                SELECT hasSecretKey FROM pgpKey WHERE accountId = ? AND fingerprint = ?
                """, arguments: [self.a, self.k1.fingerprint]), true)
        }
    }

    func testReimportingACertificateKeepsItsSecretHalf() async throws {
        let q = try makeDB()
        let secrets = MemorySecretKeys()
        let storeA = store(a, q, secrets)
        try await storeA.addCertificates([PGPArmoredKey(key: k1, armored: cert("1"))])
        try await storeA.addSecretKeys([PGPArmoredKey(key: k1, armored: secret("1"))])
        try await storeA.addCertificates([PGPArmoredKey(key: k1, armored: cert("1 updated"))])
        let certs = try await storeA.certificates()
        let keys = try await storeA.secretKeys()
        XCTAssertEqual(certs, cert("1 updated"))
        XCTAssertEqual(keys, secret("1"))
    }

    func testASecretKeyWithoutItsCertificateIsNotKept() async throws {
        let q = try makeDB()
        let secrets = MemorySecretKeys()
        do {
            try await store(a, q, secrets).addSecretKeys([PGPArmoredKey(key: k1, armored: secret("1"))])
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? PGPEngineError, .malformed)
        }
        XCTAssertEqual(secrets.stored, [:])
    }

    func testDeletingAKeyRemovesBothHalvesAndThePassphrase() async throws {
        let q = try makeDB()
        let secrets = MemorySecretKeys()
        let passphrases = PGPPassphrases()
        let storeA = store(a, q, secrets, passphrases)
        try await storeA.addCertificates([PGPArmoredKey(key: k1, armored: cert("1")),
                                          PGPArmoredKey(key: k2, armored: cert("2"))])
        try await storeA.addSecretKeys([PGPArmoredKey(key: k1, armored: secret("1"))])
        passphrases.set(Data("pw".utf8), accountId: a)
        let typed = try await storeA.passphrase()
        XCTAssertEqual(typed, Data("pw".utf8))

        try await storeA.remove(k1)
        XCTAssertEqual(secrets.stored, [:])
        XCTAssertNil(passphrases.passphrase(accountId: a))
        let left = try await q.read { try PGPKeyTable.rows($0, accountId: self.a).map(\.fingerprint) }
        XCTAssertEqual(left, [k2.fingerprint])
    }

    /// A Keychain that refuses the delete fails the call and the key stays
    /// listed, so nothing is left that the list does not show.
    func testAKeychainThatRefusesTheDeleteKeepsTheKeyListed() async throws {
        let q = try makeDB()
        let secrets = MemorySecretKeys()
        let storeA = store(a, q, secrets)
        try await storeA.addCertificates([PGPArmoredKey(key: k1, armored: cert("1"))])
        try await storeA.addSecretKeys([PGPArmoredKey(key: k1, armored: secret("1"))])
        secrets.refusesDeletes = true
        do {
            try await storeA.remove(k1)
            XCTFail("expected a failure")
        } catch {}
        let left = try await q.read { try PGPKeyTable.rows($0, accountId: self.a).count }
        XCTAssertEqual(left, 1)
    }

    /// DEC-019: the account purge takes its rows; the Keychain sweep takes
    /// the secret keys the database no longer lists.
    func testAccountRemovalLeavesNoKeyBehind() async throws {
        let q = try makeDB()
        let secrets = MemorySecretKeys()
        for account in [a, b] {
            let s = store(account, q, secrets)
            try await s.addCertificates([PGPArmoredKey(key: k1, armored: cert(account))])
            try await s.addSecretKeys([PGPArmoredKey(key: k1, armored: secret(account))])
        }
        try await q.write { try AccountLifecycle.purgeAccount($0, id: self.a) }
        let rows = try await q.read { try PGPKeyRecord.fetchAll($0).map(\.accountId) }
        XCTAssertEqual(rows, [b])

        let keep = try await q.read { try PGPKeyTable.secretKeyOwners($0) }
        try secrets.deleteAll(except: keep)
        XCTAssertEqual(Array(secrets.stored.keys), [PGPSecretKeyOwner(accountId: b, key: k1)])

        try secrets.deleteAll(accountId: b)
        XCTAssertEqual(secrets.stored, [:])
    }

    func testOrphanRowsArePurged() async throws {
        let q = try makeDB()
        try await store(a, q, MemorySecretKeys()).addCertificates([PGPArmoredKey(key: k1, armored: cert("1"))])
        // Outside a transaction, or the pragma does nothing.
        try q.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [self.a])
            XCTAssertEqual(try PGPKeyRecord.fetchCount(db), 1)
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try PGPKeyTable.purgeOrphans(db)
            XCTAssertEqual(try PGPKeyRecord.fetchCount(db), 0)
        }
    }

    func testKeychainItemNamesRoundTrip() {
        for owner in [PGPSecretKeyOwner(accountId: "a@x.com", key: k1),
                      PGPSecretKeyOwner(accountId: "odd:name@x.com", key: k2)] {
            XCTAssertEqual(KeychainPGPSecretKeys.owner(fromItemName: KeychainPGPSecretKeys.itemName(owner)), owner)
        }
        for junk in ["", "refreshToken.a@x.com", "secretKey:", "secretKey:AAAA", "secretKey::a@x.com",
                     "secretKey:NOTHEX:a@x.com"] {
            XCTAssertNil(KeychainPGPSecretKeys.owner(fromItemName: junk), junk)
        }
    }

    func testPassphrasesArePerAccountAndForgotten() {
        let passphrases = PGPPassphrases()
        passphrases.set(Data("one".utf8), accountId: a)
        XCTAssertNil(passphrases.passphrase(accountId: b))
        passphrases.forget(accountId: a)
        XCTAssertNil(passphrases.passphrase(accountId: a))
    }
}

/// v62 (this branch) registers before v63 and v64, which merged first. A
/// database that already ran them from `main` must still get v62.
final class PGPKeyMigrationOrderTests: XCTestCase {
    func testV62RunsOnADatabaseThatAlreadyHasV63AndV64() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try db.drop(table: "pgpKey")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v62'")
        }
        try q.read { db in
            let applied = try AppDatabase.migrator.appliedIdentifiers(db)
            XCTAssertTrue(applied.contains("v63"))
            XCTAssertTrue(applied.contains("v64"))
            XCTAssertFalse(applied.contains("v62"))
        }
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            XCTAssertTrue(try AppDatabase.migrator.appliedIdentifiers(db).contains("v62"))
            XCTAssertTrue(try db.tableExists("pgpKey"))
            XCTAssertTrue(try AppDatabase.migrator.hasCompletedMigrations(db))
        }
    }
}
