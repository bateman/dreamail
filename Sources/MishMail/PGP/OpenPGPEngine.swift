import Foundation

/// The seam where an OpenPGP library plugs in (step 4B). Everything else in
/// `PGP/` talks to this protocol only, so the library is one conforming type
/// and nothing around it changes.
///
/// Scope B (owner's decision): verify, decrypt, import keys by hand, list
/// and delete them. Signing, encryption, key generation and network lookup
/// are not part of the protocol; scope C adds them.
///
/// The conforming type owns the keys: where they are stored (secret keys in
/// the Keychain, this device only; certificates in the encrypted database),
/// how the passphrase is obtained (it asks through its own prompt; `decrypt`
/// throws `.passphraseRequired` when none is available, and the caller asks
/// again later), and deletion: `deleteKey` must leave nothing behind (DEC-019,
/// "deleted means gone"), and an account's keys go when the account goes.
///
/// Inputs are bytes exactly as the message carries them: for a detached
/// signature, the canonical (CRLF) bytes of the signed MIME part
/// (`PGPInspection`); for armored data, the armor text undecoded. Results say
/// what the library established and nothing more; `PGPSecurityRules`
/// decides what the user sees. An engine must not log message text,
/// plaintext or key material.
protocol OpenPGPEngine: Sendable {
    /// Verifies a detached signature (`application/pgp-signature`) over
    /// `signedData`.
    func verifyDetached(signedData: Data, signature: Data) async throws -> [PGPSignatureResult]

    /// Verifies a cleartext-signed message (`BEGIN PGP SIGNED MESSAGE`). The
    /// returned text is the signed text as the engine read it, dash-escaping
    /// undone: the only text that may be shown as signed.
    func verifyCleartext(_ message: Data) async throws -> PGPCleartextResult

    /// Decrypts a message (`BEGIN PGP MESSAGE` or binary), verifying any
    /// signature inside it.
    ///
    /// Contract: plaintext is returned only when the engine verified an
    /// integrity check (SEIPD v1 MDC or v2 AEAD) before releasing it.
    /// Otherwise it throws `.notIntegrityProtected` and no plaintext leaves
    /// the engine (EFAIL), so a caller has nothing it could show or log.
    func decrypt(_ message: Data) async throws -> PGPDecryptionResult

    /// Reads keys from armored or binary data and stores them. Returns what
    /// was imported; the import screen shows each fingerprint and every user
    /// ID as unverified.
    func importKeys(_ data: Data) async throws -> [PGPKeySummary]

    /// Every stored key.
    func keys() async throws -> [PGPKeySummary]

    /// Removes a key, public and secret parts, from every store.
    func deleteKey(_ key: PGPKeyReference) async throws
}

/// A key by its full fingerprint (hex, uppercase, no spaces).
struct PGPKeyReference: Sendable, Hashable {
    let fingerprint: String

    init(fingerprint: String) {
        self.fingerprint = fingerprint.uppercased().filter { !$0.isWhitespace }
    }
}

struct PGPKeySummary: Sendable, Equatable {
    let key: PGPKeyReference
    /// User IDs as the key states them (e.g. `Name <addr@example.org>`),
    /// without revoked ones. None of them is verified: anyone can put any
    /// address in a key they make.
    let userIDs: [String]
    let hasSecretKey: Bool
    let created: Date?
    let expires: Date?
    let isRevoked: Bool
}

/// One signature's outcome, as the engine established it.
enum PGPSignatureResult: Sendable, Equatable {
    /// Cryptographically good, by a key the engine has.
    case good(signer: PGPKeySummary)
    /// The signature does not match the data, or is malformed.
    case bad
    /// No public key for the issuer. `keyID` is what the signature names.
    case unknownKey(keyID: String)
    /// Good maths, but the key is expired or revoked.
    case keyNotValid(signer: PGPKeySummary)
    /// An algorithm or version the engine refuses.
    case unsupported
}

struct PGPCleartextResult: Sendable, Equatable {
    let signedText: Data
    let signatures: [PGPSignatureResult]
}

/// Integrity-checked plaintext: an engine cannot build one any other way
/// (see `OpenPGPEngine.decrypt`).
struct PGPDecryptionResult: Sendable, Equatable {
    let plaintext: Data
    /// Signatures found inside the encrypted data, verified.
    let signatures: [PGPSignatureResult]
}

enum PGPEngineError: Error, Sendable, Equatable {
    /// No OpenPGP library in this build.
    case unavailable
    /// No secret key for any recipient of the message.
    case noSecretKey
    /// The secret key is locked and no (or a wrong) passphrase was given.
    case passphraseRequired
    /// Decryption worked but there was no integrity check to verify: the
    /// plaintext was discarded.
    case notIntegrityProtected
    /// Not OpenPGP data, or damaged.
    case malformed
    case unsupported
}

/// The engine of a build without an OpenPGP library: every call refuses.
struct UnavailableOpenPGPEngine: OpenPGPEngine {
    func verifyDetached(signedData: Data, signature: Data) async throws -> [PGPSignatureResult] {
        throw PGPEngineError.unavailable
    }
    func verifyCleartext(_ message: Data) async throws -> PGPCleartextResult {
        throw PGPEngineError.unavailable
    }
    func decrypt(_ message: Data) async throws -> PGPDecryptionResult {
        throw PGPEngineError.unavailable
    }
    func importKeys(_ data: Data) async throws -> [PGPKeySummary] {
        throw PGPEngineError.unavailable
    }
    func keys() async throws -> [PGPKeySummary] {
        throw PGPEngineError.unavailable
    }
    func deleteKey(_ key: PGPKeyReference) async throws {
        throw PGPEngineError.unavailable
    }
}
