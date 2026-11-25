import Foundation

/// A stand-in `OpenPGPEngine` for tests. It does no cryptography: answers
/// are configured per input, and every call is recorded so a test can show
/// exactly which bytes reached the engine, or that nothing did.
final class FakeOpenPGPEngine: OpenPGPEngine, @unchecked Sendable {
    enum Call: Equatable {
        case verifyDetached(signedData: Data, signature: Data)
        case verifyCleartext(Data)
        case decrypt(Data)
        case sign(Data, PGPKeyReference, detached: Bool)
        case encrypt(Data, [PGPKeyReference], PGPKeyReference?)
        case importKeys(Data)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    /// Answer for `verifyDetached`, keyed by the exact signed bytes. Any
    /// other bytes verify as `.bad`, as a real engine would answer for data
    /// that was changed.
    var detachedResults: [Data: [PGPSignatureResult]] = [:]
    var decryption: Result<PGPDecryptionResult, PGPEngineError> = .failure(.noSecretKey)
    var cleartext: Result<PGPCleartextResult, PGPEngineError> = .failure(.malformed)
    var imported: [PGPKeySummary] = []

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private func record(_ call: Call) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(call)
    }

    func verifyDetached(signedData: Data, signature: Data) async throws -> [PGPSignatureResult] {
        record(.verifyDetached(signedData: signedData, signature: signature))
        return detachedResults[signedData] ?? [.bad]
    }

    func verifyCleartext(_ message: Data) async throws -> PGPCleartextResult {
        record(.verifyCleartext(message))
        return try cleartext.get()
    }

    func decrypt(_ message: Data) async throws -> PGPDecryptionResult {
        record(.decrypt(message))
        return try decryption.get()
    }

    func sign(_ data: Data, as signer: PGPKeyReference, detached: Bool) async throws -> Data {
        record(.sign(data, signer, detached: detached))
        return Data(PGPCorpus.fakeSignature.utf8)
    }

    func encrypt(_ data: Data, to recipients: [PGPKeyReference],
                 signedBy signer: PGPKeyReference?) async throws -> Data {
        record(.encrypt(data, recipients, signer))
        return Data(PGPCorpus.fakeMessage.utf8)
    }

    func importKeys(_ data: Data) async throws -> [PGPKeySummary] {
        record(.importKeys(data))
        return imported
    }

    // MARK: - Test keys (summaries only; no key material exists)

    static func key(_ fingerprint: String, _ userIDs: [String]) -> PGPKeySummary {
        PGPKeySummary(key: PGPKeyReference(fingerprint: fingerprint), userIDs: userIDs,
                      hasSecretKey: false, created: nil, expires: nil, isRevoked: false)
    }

    static let alice = key("AAAA 0000 TEST ONLY 0000 AAAA", ["Alice Example <alice@example.org>"])
    static let mallory = key("BBBB 0000 TEST ONLY 0000 BBBB", ["Mallory <mallory@example.net>"])
}
