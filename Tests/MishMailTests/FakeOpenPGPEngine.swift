import Foundation

/// A stand-in `OpenPGPEngine` for tests. It does no cryptography: answers
/// are configured per input, and every call is recorded so a test can show
/// exactly which bytes reached the engine, or that nothing did.
final class FakeOpenPGPEngine: OpenPGPEngine, @unchecked Sendable {
    enum Call: Equatable {
        case verifyDetached(signedData: Data, signature: Data)
        case verifyCleartext(Data)
        case decrypt(Data)
        case importKeys(Data)
        case importSecretKeys(Data)
        case keys
        case deleteKey(PGPKeyReference)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var stored: [PGPKeySummary] = []

    /// Answer for `verifyDetached`, keyed by the exact signed bytes. Any
    /// other bytes verify as `.bad`, as a real engine would answer for data
    /// that was changed.
    var detachedResults: [Data: [PGPSignatureResult]] = [:]
    var decryption: Result<PGPDecryptionResult, PGPEngineError> = .failure(.noSecretKey)
    var cleartext: Result<PGPCleartextResult, PGPEngineError> = .failure(.malformed)
    /// What `importKeys` reads out of any data.
    var importable: [PGPKeySummary] = []

    var calls: [Call] { locked { recorded } }

    private func record(_ call: Call) {
        locked { recorded.append(call) }
    }

    /// Synchronous, so it can be called from the async methods.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
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

    func importKeys(_ data: Data) async throws -> [PGPKeySummary] {
        record(.importKeys(data))
        return locked {
            stored += importable.filter { key in !stored.contains { $0.key == key.key } }
            return importable
        }
    }

    func importSecretKeys(_ data: Data) async throws -> [PGPKeySummary] {
        record(.importSecretKeys(data))
        return locked {
            stored += importable.filter { key in !stored.contains { $0.key == key.key } }
            return importable
        }
    }

    func keys() async throws -> [PGPKeySummary] {
        record(.keys)
        return locked { stored }
    }

    func deleteKey(_ key: PGPKeyReference) async throws {
        record(.deleteKey(key))
        locked { stored.removeAll { $0.key == key } }
    }

    // MARK: - Test keys (summaries only; no key material exists)

    static func key(_ fingerprint: String, _ userIDs: [String]) -> PGPKeySummary {
        PGPKeySummary(key: PGPKeyReference(fingerprint: fingerprint), userIDs: userIDs,
                      hasSecretKey: false, created: nil, expires: nil, validity: .valid)
    }

    static let alice = key("AAAA 0000 TEST ONLY 0000 AAAA", ["Alice Example <alice@example.org>"])
    static let mallory = key("BBBB 0000 TEST ONLY 0000 BBBB", ["Mallory <mallory@example.net>"])
}
