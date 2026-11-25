import Foundation

/// The seam where an OpenPGP library plugs in (step 4B). Everything else in
/// `PGP/` talks to this protocol only, so the library chosen later is one
/// conforming type and nothing around it changes.
///
/// Inputs are bytes exactly as the message carries them: for a detached
/// signature, the canonical (CRLF) bytes of the signed MIME part from
/// `PGPSignedPart`; for armored data, the armor text undecoded. Results say
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
    func decrypt(_ message: Data) async throws -> PGPDecryptionResult

    /// A signature over `data` by `signer`'s secret key: detached for
    /// PGP/MIME, cleartext otherwise. Armored.
    func sign(_ data: Data, as signer: PGPKeyReference, detached: Bool) async throws -> Data

    /// `data` encrypted to every recipient (and signed when `signer` is set).
    /// Armored.
    func encrypt(_ data: Data, to recipients: [PGPKeyReference],
                 signedBy signer: PGPKeyReference?) async throws -> Data

    /// Reads keys from armored or binary data and adds them to the engine's
    /// key store. Returns what was imported.
    func importKeys(_ data: Data) async throws -> [PGPKeySummary]
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
    /// User IDs as the key states them (e.g. `Name <addr@example.org>`).
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
    /// Good maths, but the key was expired or revoked when it signed, or
    /// the signature itself has expired.
    case keyNotValid(signer: PGPKeySummary)
    /// An algorithm or version the engine refuses.
    case unsupported
}

struct PGPCleartextResult: Sendable, Equatable {
    let signedText: Data
    let signatures: [PGPSignatureResult]
}

struct PGPDecryptionResult: Sendable, Equatable {
    let plaintext: Data
    /// True only with an integrity check the engine verified (SEIPD v1 MDC
    /// or v2 AEAD). Without one the plaintext must not be shown (EFAIL).
    let integrityProtected: Bool
    /// Signatures found inside the encrypted data, verified.
    let signatures: [PGPSignatureResult]
}

enum PGPEngineError: Error, Sendable, Equatable {
    /// No OpenPGP library in this build.
    case unavailable
    /// No secret key for any recipient of the message.
    case noSecretKey
    /// The secret key is locked and no passphrase was given.
    case passphraseRequired
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
    func sign(_ data: Data, as signer: PGPKeyReference, detached: Bool) async throws -> Data {
        throw PGPEngineError.unavailable
    }
    func encrypt(_ data: Data, to recipients: [PGPKeyReference],
                 signedBy signer: PGPKeyReference?) async throws -> Data {
        throw PGPEngineError.unavailable
    }
    func importKeys(_ data: Data) async throws -> [PGPKeySummary] {
        throw PGPEngineError.unavailable
    }
}
