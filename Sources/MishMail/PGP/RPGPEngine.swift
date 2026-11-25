import Foundation
#if canImport(MishMailRPGP)
import MishMailRPGP
#endif

/// `OpenPGPEngine` over rPGP, through the dreamail-openpgp package (step 4B,
/// scope B: verify, decrypt, read keys).
///
/// Split in two so the part that can be wrong is tested without the
/// library: `RPGPEngine` turns calls into byte buffers and the library's
/// JSON answers into the engine types, and is compiled and tested always;
/// `LinkedRPGPBindings`, a few lines that call the C functions, is compiled
/// only when the `MishMailRPGP` module is linked into the build.
///
/// The library is stateless. Keys live in `PGPKeyStore` (secret keys in the
/// Keychain, certificates in the encrypted database, in the step that
/// stores them) and are read on every call; nothing is cached here.
struct RPGPEngine: OpenPGPEngine {
    let bindings: any RPGPBindings
    let store: any PGPKeyStore
    var now: @Sendable () -> Date = { Date() }

    func verifyDetached(signedData: Data, signature: Data) async throws -> [PGPSignatureResult] {
        let certs = try await store.certificates()
        let reply = bindings.verifyDetached(signedData, signature, certs, unixNow)
        return try RPGPReply.decode(reply.json).signatures()
    }

    func verifyCleartext(_ message: Data) async throws -> PGPCleartextResult {
        let certs = try await store.certificates()
        let reply = bindings.verifyCleartext(message, certs, unixNow)
        let decoded = try RPGPReply.decode(reply.json)
        return PGPCleartextResult(signedText: reply.data, signatures: try decoded.signatures())
    }

    /// Plaintext leaves only with the library's explicit statement that an
    /// integrity check was verified; anything else is discarded and reported
    /// as `.notIntegrityProtected`.
    func decrypt(_ message: Data) async throws -> PGPDecryptionResult {
        let secrets = try await store.secretKeys()
        guard !secrets.isEmpty else { throw PGPEngineError.noSecretKey }
        let certs = try await store.certificates()
        let passphrase = try await store.passphrase()
        let reply = bindings.decrypt(message, secrets, passphrase, certs, unixNow)
        let decoded = try RPGPReply.decode(reply.json)
        guard decoded.integrityProtected == true else { throw PGPEngineError.notIntegrityProtected }
        return PGPDecryptionResult(plaintext: reply.data, signatures: try decoded.signatures())
    }

    /// Reads the keys, then hands them to the store; returns what they are.
    func importKeys(_ data: Data) async throws -> [PGPKeySummary] {
        let reply = bindings.inspectKeys(data, unixNow)
        let keys = try RPGPReply.decode(reply.json).keys ?? []
        try await store.add(data)
        return keys
    }

    func keys() async throws -> [PGPKeySummary] {
        var all = Data()
        all.append(try await store.certificates())
        all.append(try await store.secretKeys())
        guard !all.isEmpty else { return [] }
        let reply = bindings.inspectKeys(all, unixNow)
        return try RPGPReply.decode(reply.json).keys ?? []
    }

    func deleteKey(_ key: PGPKeyReference) async throws {
        try await store.remove(key)
    }

    private var unixNow: Int64 { Int64(now().timeIntervalSince1970) }
}

/// Where the keys are. The store owns the passphrase prompt and deletion
/// (`remove` leaves nothing behind, DEC-019); an account's keys go with the
/// account.
protocol PGPKeyStore: Sendable {
    /// Every certificate (public key), concatenated, armored or binary.
    func certificates() async throws -> Data
    /// Every secret key, concatenated.
    func secretKeys() async throws -> Data
    /// The passphrase for the secret keys; empty when they have none.
    func passphrase() async throws -> Data
    /// Stores keys the engine has read (public into certificates, secret
    /// into the secret store).
    func add(_ keys: Data) async throws
    /// Removes a key, public and secret parts.
    func remove(_ key: PGPKeyReference) async throws
}

/// The C functions as Swift closures, so tests can stand in for them.
protocol RPGPBindings: Sendable {
    func verifyDetached(_ data: Data, _ signature: Data, _ certs: Data, _ now: Int64) -> RPGPRawReply
    func verifyCleartext(_ message: Data, _ certs: Data, _ now: Int64) -> RPGPRawReply
    func decrypt(_ message: Data, _ secretKeys: Data, _ passphrase: Data, _ certs: Data,
                 _ now: Int64) -> RPGPRawReply
    func inspectKeys(_ data: Data, _ now: Int64) -> RPGPRawReply
}

struct RPGPRawReply: Sendable, Equatable {
    let json: Data
    let data: Data
}

/// The library's JSON answer (see `rust/src/lib.rs` in dreamail-openpgp).
struct RPGPReply: Decodable, Equatable {
    struct Key: Decodable, Equatable {
        let fingerprint: String
        let userIDs: [String]
        let hasSecret: Bool
        let created: Int64
        let expires: Int64?
        let revoked: Bool

        enum CodingKeys: String, CodingKey {
            case fingerprint, created, expires, revoked
            case userIDs = "user_ids"
            case hasSecret = "has_secret"
        }

        var summary: PGPKeySummary {
            PGPKeySummary(key: PGPKeyReference(fingerprint: fingerprint), userIDs: userIDs,
                          hasSecretKey: hasSecret,
                          created: Date(timeIntervalSince1970: TimeInterval(created)),
                          expires: expires.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                          isRevoked: revoked)
        }
    }

    struct Signature: Decodable, Equatable {
        let status: String
        let signer: Key?
        let keyID: String?

        enum CodingKeys: String, CodingKey {
            case status, signer
            case keyID = "key_id"
        }
    }

    let ok: Bool
    let error: String?
    let integrityProtected: Bool?
    let rawSignatures: [Signature]?
    let rawKeys: [Key]?

    enum CodingKeys: String, CodingKey {
        case ok, error
        case integrityProtected = "integrity_protected"
        case rawSignatures = "signatures"
        case rawKeys = "keys"
    }

    var keys: [PGPKeySummary]? { rawKeys?.map(\.summary) }

    /// Unknown statuses are not trusted: they read as `.unsupported`. A
    /// "good" or "key not valid" without its signer is malformed.
    func signatures() throws -> [PGPSignatureResult] {
        try (rawSignatures ?? []).map { sig in
            switch sig.status {
            case "good":
                guard let signer = sig.signer else { throw PGPEngineError.malformed }
                return .good(signer: signer.summary)
            case "key_not_valid":
                guard let signer = sig.signer else { throw PGPEngineError.malformed }
                return .keyNotValid(signer: signer.summary)
            case "bad": return .bad
            case "unknown_key": return .unknownKey(keyID: sig.keyID ?? "")
            default: return .unsupported
            }
        }
    }

    /// Decodes a reply; a reply that says `ok: false` becomes its error.
    static func decode(_ json: Data) throws -> RPGPReply {
        guard let reply = try? JSONDecoder().decode(RPGPReply.self, from: json) else {
            throw PGPEngineError.malformed
        }
        guard reply.ok else {
            switch reply.error {
            case "no_secret_key": throw PGPEngineError.noSecretKey
            case "passphrase_required": throw PGPEngineError.passphraseRequired
            case "unsupported": throw PGPEngineError.unsupported
            default: throw PGPEngineError.malformed
            }
        }
        return reply
    }
}

#if canImport(MishMailRPGP)
/// The linked library. Each call copies its result out and frees (and
/// zeroes) the library's buffers before returning.
struct LinkedRPGPBindings: RPGPBindings {
    func verifyDetached(_ data: Data, _ signature: Data, _ certs: Data, _ now: Int64) -> RPGPRawReply {
        Self.take(data.withUnsafeBytes { d in signature.withUnsafeBytes { s in certs.withUnsafeBytes { c in
            mm_pgp_verify_detached(Self.ptr(d), d.count, Self.ptr(s), s.count, Self.ptr(c), c.count, now)
        } } })
    }

    func verifyCleartext(_ message: Data, _ certs: Data, _ now: Int64) -> RPGPRawReply {
        Self.take(message.withUnsafeBytes { m in certs.withUnsafeBytes { c in
            mm_pgp_verify_cleartext(Self.ptr(m), m.count, Self.ptr(c), c.count, now)
        } })
    }

    func decrypt(_ message: Data, _ secretKeys: Data, _ passphrase: Data, _ certs: Data,
                 _ now: Int64) -> RPGPRawReply {
        Self.take(message.withUnsafeBytes { m in secretKeys.withUnsafeBytes { k in
            passphrase.withUnsafeBytes { p in certs.withUnsafeBytes { c in
                mm_pgp_decrypt(Self.ptr(m), m.count, Self.ptr(k), k.count, Self.ptr(p), p.count,
                               Self.ptr(c), c.count, now)
            } }
        } })
    }

    func inspectKeys(_ data: Data, _ now: Int64) -> RPGPRawReply {
        Self.take(data.withUnsafeBytes { d in mm_pgp_inspect_keys(Self.ptr(d), d.count, now) })
    }

    private static func ptr(_ buffer: UnsafeRawBufferPointer) -> UnsafePointer<UInt8>? {
        buffer.bindMemory(to: UInt8.self).baseAddress
    }

    private static func take(_ result: MMResult) -> RPGPRawReply {
        defer { mm_pgp_free(result) }
        func copy(_ b: MMBuffer) -> Data {
            guard let p = b.ptr, b.len > 0 else { return Data() }
            return Data(bytes: p, count: b.len)
        }
        return RPGPRawReply(json: copy(result.json), data: copy(result.data))
    }
}
#endif
