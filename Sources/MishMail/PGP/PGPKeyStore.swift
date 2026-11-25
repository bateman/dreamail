import Foundation
import GRDB
import Security

/// One OpenPGP key of an account (v62). The certificate is public and lives
/// in the encrypted database; a secret half, when there is one, lives in the
/// Keychain only (`PGPSecretKeyStorage`) and this row carries just the flag.
/// Cascades with the account (DEC-019).
struct PGPKeyRecord: Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pgpKey"
    var accountId: String
    /// Uppercase hex, no spaces (`PGPKeyReference`).
    var fingerprint: String
    /// The certificate as the library re-serialized it (one armored block).
    var certificate: Data
    /// A secret half is stored in the Keychain. Never the key itself.
    var hasSecretKey: Bool
    var addedAt: Date
}

enum PGPKeyTable {
    static func createTable(_ db: Database) throws {
        try db.create(table: PGPKeyRecord.databaseTableName) { t in
            t.column("accountId", .text).notNull()
                .references("account", onDelete: .cascade)
            t.column("fingerprint", .text).notNull()
            t.column("certificate", .blob).notNull()
            t.column("hasSecretKey", .boolean).notNull().defaults(to: false)
            t.column("addedAt", .datetime).notNull()
            t.primaryKey(["accountId", "fingerprint"])
        }
    }

    static func rows(_ db: Database, accountId: String) throws -> [PGPKeyRecord] {
        try PGPKeyRecord.filter(Column("accountId") == accountId)
            .order(Column("fingerprint")).fetchAll(db)
    }

    /// Also cascades with the account row; deleted by name so a removal does
    /// not depend on the foreign key alone.
    static func forget(_ db: Database, accountId: String) throws {
        _ = try PGPKeyRecord.filter(Column("accountId") == accountId).deleteAll(db)
    }

    static func purgeOrphans(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM \(PGPKeyRecord.databaseTableName)
            WHERE accountId NOT IN (SELECT id FROM account)
            """)
    }

    /// Every (account, key) whose secret half the database says is stored.
    static func secretKeyOwners(_ db: Database) throws -> Set<PGPSecretKeyOwner> {
        let rows = try PGPKeyRecord.filter(Column("hasSecretKey") == true).fetchAll(db)
        return Set(rows.map {
            PGPSecretKeyOwner(accountId: $0.accountId, key: PGPKeyReference(fingerprint: $0.fingerprint))
        })
    }
}

struct PGPSecretKeyOwner: Hashable, Sendable {
    let accountId: String
    let key: PGPKeyReference
}

/// Where secret keys are kept: the Keychain in the app, memory in tests.
protocol PGPSecretKeyStorage: Sendable {
    /// Nil when there is none; throws when the store cannot be read (a
    /// locked Keychain), so a caller never mistakes that for "no key".
    func secretKey(of owner: PGPSecretKeyOwner) throws -> Data?
    func setSecretKey(_ armored: Data, of owner: PGPSecretKeyOwner) throws
    /// Succeeds when the key is gone, also when there was none.
    func deleteSecretKey(of owner: PGPSecretKeyOwner) throws
    /// Every stored owner, for the sweep of keys whose row is gone.
    func owners() throws -> [PGPSecretKeyOwner]
}

extension PGPSecretKeyStorage {
    func deleteAll(accountId: String) throws {
        for owner in try owners() where owner.accountId == accountId {
            try deleteSecretKey(of: owner)
        }
    }

    /// Deletes every secret key the database does not list (a removed
    /// account or key whose Keychain delete failed, or was cut short).
    func deleteAll(except keep: Set<PGPSecretKeyOwner>) throws {
        for owner in try owners() where !keep.contains(owner) {
            try deleteSecretKey(of: owner)
        }
    }
}

/// Secret keys in the login Keychain, one item per account and key, under a
/// service of their own so they can be listed and removed without touching
/// the app's other secrets. Not synchronizable. The item asks for
/// "after first unlock, this device only", but without
/// `kSecUseDataProtectionKeychain` macOS keeps it in the file-based login
/// keychain and ignores that attribute: what protects it is the login
/// keychain itself (encrypted with the user's login password) and the key's
/// own passphrase, under which it stays.
struct KeychainPGPSecretKeys: PGPSecretKeyStorage {
    private static let service =
        (Bundle.main.bundleIdentifier ?? "io.github.bateman.MishMail") + ".openpgp"
    private static let prefix = "secretKey:"

    /// `secretKey:<FINGERPRINT>:<account>`: the fingerprint is hex, so the
    /// first colon after it ends it, whatever the account id holds.
    static func itemName(_ owner: PGPSecretKeyOwner) -> String {
        "\(prefix)\(owner.key.fingerprint):\(owner.accountId)"
    }

    static func owner(fromItemName name: String) -> PGPSecretKeyOwner? {
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let fingerprint = String(rest[..<colon])
        let account = String(rest[rest.index(after: colon)...])
        guard !fingerprint.isEmpty, !account.isEmpty,
              fingerprint.allSatisfy(\.isHexDigit) else { return nil }
        return PGPSecretKeyOwner(accountId: account, key: PGPKeyReference(fingerprint: fingerprint))
    }

    private func query(_ owner: PGPSecretKeyOwner) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.itemName(owner)]
    }

    func secretKey(of owner: PGPSecretKeyOwner) throws -> Data? {
        var q = query(owner)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.status(status == errSecSuccess ? errSecDecode : status)
        }
        return data
    }

    func setSecretKey(_ armored: Data, of owner: PGPSecretKeyOwner) throws {
        let q = query(owner)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: armored] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = armored
            add[kSecAttrSynchronizable as String] = false
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "MishMail OpenPGP secret key"
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError.status(added) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    func deleteSecretKey(of owner: PGPSecretKeyOwner) throws {
        let status = SecItemDelete(query(owner) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    func owners() throws -> [PGPSecretKeyOwner] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: Self.service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(Self.owner) }
    }
}

/// Passphrases the user typed to unlock a secret key, per account, held in
/// memory only: never written to disk, the database, the Keychain or a log.
/// They go when MishMail quits, the screen locks or the Mac sleeps, the
/// account goes, or one of its keys is deleted.
final class PGPPassphrases: @unchecked Sendable {
    private let lock = NSLock()
    private var byAccount: [String: Data] = [:]

    /// Every passphrase, when the screen locks or the Mac sleeps.
    func forgetAll() {
        lock.lock(); defer { lock.unlock() }
        for id in byAccount.keys { wipe(id) }
        byAccount = [:]
    }

    /// Zeroes the stored bytes before letting go of them. Copies made
    /// elsewhere (the text field's `String`, the engine call) cannot be.
    private func wipe(_ id: String) {
        guard let count = byAccount[id]?.count, count > 0 else { return }
        byAccount[id]?.resetBytes(in: 0..<count)
    }

    func passphrase(accountId: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return byAccount[accountId]
    }

    func set(_ passphrase: Data, accountId: String) {
        lock.lock(); defer { lock.unlock() }
        wipe(accountId)
        byAccount[accountId] = passphrase
    }

    func forget(accountId: String) {
        lock.lock(); defer { lock.unlock() }
        wipe(accountId)
        byAccount[accountId] = nil
    }
}

/// `PGPKeyStore` of one account: certificates from the encrypted database,
/// secret keys from `secrets`, the passphrase from memory.
struct DatabasePGPKeyStore: PGPKeyStore {
    let accountId: String
    let database: any DatabaseWriter
    let secrets: any PGPSecretKeyStorage
    let passphrases: PGPPassphrases

    private func owner(_ key: PGPKeyReference) -> PGPSecretKeyOwner {
        PGPSecretKeyOwner(accountId: accountId, key: key)
    }

    func certificates() async throws -> Data {
        let account = accountId
        let rows = try await database.read { try PGPKeyTable.rows($0, accountId: account) }
        return rows.reduce(into: Data()) { $0.append($1.certificate) }
    }

    /// The secret keys the database lists, read from the Keychain. A row
    /// whose Keychain item is missing is skipped (the key cannot decrypt);
    /// an unreadable Keychain fails the call.
    func secretKeys() async throws -> Data {
        let account = accountId
        let rows = try await database.read { try PGPKeyTable.rows($0, accountId: account) }
        var out = Data()
        for row in rows where row.hasSecretKey {
            if let key = try secrets.secretKey(of: owner(PGPKeyReference(fingerprint: row.fingerprint))) {
                out.append(key)
            }
        }
        return out
    }

    func passphrase() async throws -> Data {
        passphrases.passphrase(accountId: accountId) ?? Data()
    }

    func certificate(_ key: PGPKeyReference) async throws -> Data? {
        let account = accountId
        return try await database.read { db in
            try PGPKeyRecord.filter(Column("accountId") == account
                                        && Column("fingerprint") == key.fingerprint)
                .fetchOne(db)?.certificate
        }
    }

    /// Adds or replaces each certificate; a stored secret half stays.
    func addCertificates(_ keys: [PGPArmoredKey]) async throws {
        let account = accountId
        try await database.write { db in
            for key in keys {
                try db.execute(sql: """
                    INSERT INTO pgpKey (accountId, fingerprint, certificate, hasSecretKey, addedAt)
                    VALUES (?, ?, ?, 0, ?)
                    ON CONFLICT(accountId, fingerprint) DO UPDATE SET certificate = excluded.certificate
                    """, arguments: [account, key.key.fingerprint, key.armored, Date()])
            }
        }
    }

    /// The Keychain first, then the flag: a flag never names a key that was
    /// not stored. The certificate row must exist (`RPGPEngine` adds it
    /// first).
    func addSecretKeys(_ keys: [PGPArmoredKey]) async throws {
        try await PGPSecretKeyLock.shared.run { try await self.addSecretKeysLocked(keys) }
    }

    private func addSecretKeysLocked(_ keys: [PGPArmoredKey]) async throws {
        // What each item held before this call, so a failure puts exactly
        // that back (nil: there was none).
        var before: [(PGPSecretKeyOwner, Data?)] = []
        for key in keys {
            let owner = owner(key.key)
            if !before.contains(where: { $0.0 == owner }) {
                before.append((owner, try secrets.secretKey(of: owner)))
            }
        }
        func rollBack() {
            for (owner, old) in before {
                if let old { try? secrets.setSecretKey(old, of: owner) } else { try? secrets.deleteSecretKey(of: owner) }
            }
        }
        do {
            for key in keys {
                try secrets.setSecretKey(key.armored, of: owner(key.key))
            }
        } catch {
            rollBack()
            throw error
        }
        let account = accountId
        do {
            // One transaction: a key without its certificate row rolls back
            // every flag of the batch.
            try await database.write { db in
                for key in keys {
                    try db.execute(sql: """
                        UPDATE pgpKey SET hasSecretKey = 1 WHERE accountId = ? AND fingerprint = ?
                        """, arguments: [account, key.key.fingerprint])
                    if db.changesCount == 0 { throw PGPEngineError.malformed }
                }
            }
        } catch {
            rollBack()
            throw error
        }
    }

    /// DEC-019: the secret half (Keychain) first, then the row. A Keychain
    /// that refuses the delete fails the call with the key still listed, so
    /// the user can try again; nothing is left that the list does not show.
    func remove(_ key: PGPKeyReference) async throws {
        try await PGPSecretKeyLock.shared.run { try await self.removeLocked(key) }
    }

    private func removeLocked(_ key: PGPKeyReference) async throws {
        try secrets.deleteSecretKey(of: owner(key))
        let account = accountId
        try await database.write { db in
            _ = try PGPKeyRecord.filter(Column("accountId") == account
                                            && Column("fingerprint") == key.fingerprint).deleteAll(db)
        }
        passphrases.forget(accountId: accountId)
    }
}

/// One secret-key change at a time, process-wide: an import, a delete and
/// the launch sweep never interleave, so the sweep (which deletes Keychain
/// items no row lists) cannot catch an import between its Keychain write
/// and its flag.
actor PGPSecretKeyLock {
    static let shared = PGPSecretKeyLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
