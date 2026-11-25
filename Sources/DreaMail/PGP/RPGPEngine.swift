import Foundation
#if canImport(MishMailRPGP)
import MishMailRPGP
#endif

/// `OpenPGPEngine` over rPGP, through the dreamail-openpgp package (step 4B,
/// scope B: verify, decrypt, read and import keys).
///
/// Split in two so the part that can be wrong is tested without the
/// library: `RPGPEngine` turns calls into byte buffers and the library's
/// JSON answers into the engine types, and is compiled and tested always;
/// `LinkedRPGPBindings`, a few lines that call the C functions, is compiled
/// only when the `MishMailRPGP` module is linked into the build.
///
/// The library is stateless. Keys live in `PGPKeyStore` (secret keys in the
/// Keychain, certificates in the encrypted database) and are read on every
/// call; nothing is cached here.
///
/// The C calls are synchronous and can take a while: they run on a queue of
/// their own, never on the cooperative pool, with a cancellation check on
/// each side. Swift `Data` copies of the passphrase, secret keys and
/// plaintext cannot be wiped reliably; the library zeroes its own buffers,
/// the Swift side only keeps copies short-lived.
struct RPGPEngine: OpenPGPEngine {
    /// The library's own input limit (`MAX_INPUT` in dreamail-openpgp):
    /// larger input is refused here, before it is copied across.
    static let maxInputBytes = 48 * 1024 * 1024

    let bindings: any RPGPBindings
    let store: any PGPKeyStore
    var now: @Sendable () -> Date = { Date() }

    func verifyDetached(signedData: Data, signature: Data) async throws -> [PGPSignatureResult] {
        try Self.checkSize(signedData, signature)
        let certs = try await store.certificates()
        let now = unixNow
        let reply = try await call { $0.verifyDetached(signedData, signature, certs, now) }
        return try RPGPReply.decode(reply.json).signatures()
    }

    func verifyCleartext(_ message: Data) async throws -> PGPCleartextResult {
        try Self.checkSize(message)
        let certs = try await store.certificates()
        let now = unixNow
        let reply = try await call { $0.verifyCleartext(message, certs, now) }
        let decoded = try RPGPReply.decode(reply.json)
        return PGPCleartextResult(signedText: reply.data, signatures: try decoded.signatures())
    }

    /// Plaintext leaves only with the library's explicit statement that an
    /// integrity check was verified; anything else is discarded and reported
    /// as `.notIntegrityProtected`.
    func decrypt(_ message: Data) async throws -> PGPDecryptionResult {
        try Self.checkSize(message)
        let secrets = try await store.secretKeys()
        guard !secrets.isEmpty else { throw PGPEngineError.noSecretKey }
        let certs = try await store.certificates()
        let passphrase = try await store.passphrase()
        let now = unixNow
        let reply = try await call { $0.decrypt(message, secrets, passphrase, certs, now) }
        let decoded = try RPGPReply.decode(reply.json)
        guard decoded.integrityProtected == true else { throw PGPEngineError.notIntegrityProtected }
        return PGPDecryptionResult(plaintext: reply.data, signatures: try decoded.signatures())
    }

    func inspectKeys(_ data: Data) async throws -> [PGPKeySummary] {
        try Self.checkSize(data)
        let now = unixNow
        let reply = try await call { $0.inspectKeys(data, now) }
        return try RPGPReply.decode(reply.json).keys ?? []
    }

    /// Stores the certificates the library re-serialized after checking
    /// them, never `data` itself: one armored block per key, in the order of
    /// the keys the library lists. A stored revoked certificate is never
    /// replaced by a copy without the revocation (`keepingRevocations`).
    func importKeys(_ data: Data) async throws -> [PGPKeySummary] {
        try Self.checkSize(data)
        let now = unixNow
        let reply = try await call { $0.importPublic(data, now) }
        let keys = try RPGPReply.decode(reply.json).keys ?? []
        let blocks = try Self.pair(keys, PGPArmorBlocks.split(reply.data))
        let (kept, summaries) = try await keepingRevocations(blocks, keys)
        try await store.addCertificates(kept)
        return summaries
    }

    /// An older copy of a key, without its revocation signature or with an
    /// older self-signature, must not make a revoked or expired key valid
    /// again: where the stored certificate is revoked (and the new one is
    /// not) or expired (and the new one is valid), the stored one stays, and
    /// its summary is what the import reports. shortcut: a renewed key
    /// (later expiry) is also kept out until the old one is deleted; telling
    /// a renewal from a replay, by merging certificates, belongs in the
    /// library.
    private func keepingRevocations(_ blocks: [PGPArmoredKey], _ keys: [PGPKeySummary])
        async throws -> ([PGPArmoredKey], [PGPKeySummary]) {
        var kept: [PGPArmoredKey] = []
        var summaries: [PGPKeySummary] = []
        let now = unixNow
        for (block, key) in zip(blocks, keys) {
            if key.validity != .revoked, let stored = try await store.certificate(block.key) {
                let reply = try await call { $0.inspectKeys(stored, now) }
                if let old = try RPGPReply.decode(reply.json).keys?.first(where: { $0.key == block.key }),
                   old.validity == .revoked || (old.validity == .expired && key.validity == .valid) {
                    summaries.append(old)
                    continue
                }
            }
            kept.append(block)
            summaries.append(key)
        }
        return (kept, summaries)
    }

    /// A separate, explicit action: valid secret keys, re-serialized, into
    /// the secret store; their public halves into the certificates (first,
    /// so a key's secret half is never stored without its certificate).
    func importSecretKeys(_ data: Data) async throws -> [PGPKeySummary] {
        try Self.checkSize(data)
        let now = unixNow
        let secret = try await call { $0.importSecret(data, now) }
        let keys = try RPGPReply.decode(secret.json).keys ?? []
        guard !keys.isEmpty else { throw PGPEngineError.noSecretKey }
        let secretBlocks = try Self.pair(keys, PGPArmorBlocks.split(secret.data))
        let secretData = secret.data
        let publicHalves = try await call { $0.importPublic(secretData, now) }
        let publicKeys = try RPGPReply.decode(publicHalves.json).keys ?? []
        let publicBlocks = try Self.pair(publicKeys, PGPArmorBlocks.split(publicHalves.data))
        guard Set(publicBlocks.map(\.key)).isSuperset(of: secretBlocks.map(\.key)) else {
            throw PGPEngineError.malformed
        }
        let (kept, _) = try await keepingRevocations(publicBlocks, publicKeys)
        try await store.addCertificates(kept)
        try await store.addSecretKeys(secretBlocks)
        return keys
    }

    /// Each store read on its own, merged by fingerprint: a key whose
    /// secret half is stored is listed once, with `hasSecretKey`.
    func keys() async throws -> [PGPKeySummary] {
        var merged: [PGPKeySummary] = []
        let secretKeys = try await store.secretKeys()
        let certificates = try await store.certificates()
        let now = unixNow
        for (blob, secret) in [(secretKeys, true), (certificates, false)] where !blob.isEmpty {
            let reply = try await call { $0.inspectKeys(blob, now) }
            let listed = try RPGPReply.decode(reply.json).keys ?? []
            for key in listed where !merged.contains(where: { $0.key == key.key }) {
                merged.append(secret && !key.hasSecretKey ? key.withSecret : key)
            }
        }
        return merged
    }

    func deleteKey(_ key: PGPKeyReference) async throws {
        try await store.remove(key)
    }

    private var unixNow: Int64 { Int64(now().timeIntervalSince1970) }

    private static func checkSize(_ inputs: Data...) throws {
        if inputs.contains(where: { $0.count > maxInputBytes }) { throw PGPEngineError.tooLarge }
    }

    /// The library writes one armored block per listed key, in order. Any
    /// other count means the answer cannot be trusted to say which block is
    /// which key: nothing is stored.
    private static func pair(_ keys: [PGPKeySummary], _ blocks: [Data]) throws -> [PGPArmoredKey] {
        guard !keys.isEmpty, keys.count == blocks.count else { throw PGPEngineError.malformed }
        return zip(keys, blocks).map { PGPArmoredKey(key: $0.key, armored: $1) }
    }

    /// The library's calls run here: synchronous and possibly slow, so off
    /// the cooperative pool.
    private static let queue = DispatchQueue(label: "io.github.bateman.DreaMail.rpgp",
                                             qos: .userInitiated, attributes: .concurrent)

    private func call(_ body: @escaping @Sendable (any RPGPBindings) -> RPGPRawReply)
        async throws -> RPGPRawReply {
        try Task.checkCancellation()
        let bindings = self.bindings
        let reply = await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume(returning: body(bindings)) }
        }
        try Task.checkCancellation()
        return reply
    }
}

private extension PGPKeySummary {
    var withSecret: PGPKeySummary {
        PGPKeySummary(key: key, userIDs: userIDs, hasSecretKey: true, created: created,
                      expires: expires, validity: validity)
    }
}

/// The engine of this build: rPGP when the library is linked, otherwise
/// one that refuses every call.
enum PGPEngines {
    static func engine(store: any PGPKeyStore) -> any OpenPGPEngine {
        #if canImport(MishMailRPGP)
        RPGPEngine(bindings: LinkedRPGPBindings(), store: store)
        #else
        UnavailableOpenPGPEngine()
        #endif
    }
}

/// One key as the library re-serialized it: a single armored block.
struct PGPArmoredKey: Sendable, Equatable {
    let key: PGPKeyReference
    let armored: Data
}

/// Splits concatenated armored blocks (the library's own output) at their
/// framing lines. Framing only: nothing inside a block is read.
enum PGPArmorBlocks {
    static func split(_ data: Data) -> [Data] {
        var blocks: [Data] = []
        var current: [UInt8]?
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            let text = String(decoding: line, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
            if text.hasPrefix("-----BEGIN PGP ") { current = [] }
            if current != nil {
                current?.append(contentsOf: text.utf8)
                current?.append(UInt8(ascii: "\n"))
            }
            if text.hasPrefix("-----END PGP "), let block = current {
                blocks.append(Data(block))
                current = nil
            }
        }
        return blocks
    }
}

/// Where the keys are. The store owns the passphrase prompt and deletion
/// (`remove` leaves nothing behind, DEC-019); an account's keys go with the
/// account. It only ever receives keys the library re-serialized.
protocol PGPKeyStore: Sendable {
    /// Every certificate (public key), concatenated, armored or binary.
    func certificates() async throws -> Data
    /// The stored certificate of one key, if any.
    func certificate(_ key: PGPKeyReference) async throws -> Data?
    /// Every secret key, concatenated.
    func secretKeys() async throws -> Data
    /// The passphrase for the secret keys; empty when they have none.
    func passphrase() async throws -> Data
    /// Adds or replaces certificates, one per key.
    func addCertificates(_ keys: [PGPArmoredKey]) async throws
    /// Adds or replaces secret keys, one per key; each key's certificate is
    /// already stored.
    func addSecretKeys(_ keys: [PGPArmoredKey]) async throws
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
    func importPublic(_ data: Data, _ now: Int64) -> RPGPRawReply
    func importSecret(_ data: Data, _ now: Int64) -> RPGPRawReply
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
        let validity: String

        enum CodingKeys: String, CodingKey {
            case fingerprint, created, expires, validity
            case userIDs = "user_ids"
            case hasSecret = "has_secret"
        }

        var summary: PGPKeySummary {
            PGPKeySummary(key: PGPKeyReference(fingerprint: fingerprint), userIDs: userIDs,
                          hasSecretKey: hasSecret,
                          created: Date(timeIntervalSince1970: TimeInterval(created)),
                          expires: expires.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                          // An unknown state is not trusted.
                          validity: PGPKeyValidity(rawValue: validity) ?? .unsupported)
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
            case "not_integrity_protected": throw PGPEngineError.notIntegrityProtected
            case "too_large": throw PGPEngineError.tooLarge
            case "unsupported": throw PGPEngineError.unsupported
            // "malformed", "internal" (a caught panic, a refused clock) and
            // anything unknown: nothing the library said can be used.
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

    func importPublic(_ data: Data, _ now: Int64) -> RPGPRawReply {
        Self.take(data.withUnsafeBytes { d in mm_pgp_import_public(Self.ptr(d), d.count, now) })
    }

    func importSecret(_ data: Data, _ now: Int64) -> RPGPRawReply {
        Self.take(data.withUnsafeBytes { d in mm_pgp_import_secret(Self.ptr(d), d.count, now) })
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
