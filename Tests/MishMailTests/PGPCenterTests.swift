import XCTest
import GRDB

/// The app's OpenPGP center (step 4B): off, it reads, fetches and stores
/// nothing; on, it checks a candidate message once, keeps the result in
/// memory, asks for a passphrase, and keeps remote content blocked until a
/// message is known.
@MainActor
final class PGPCenterTests: XCTestCase {

    private func makeCenter(enabled: Bool, engine: FakeOpenPGPEngine = FakeOpenPGPEngine(),
                            defaults: UserDefaults = .standard) throws -> PGPCenter {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return PGPCenter(database: q, enabled: enabled, secrets: MemorySecretKeys(), defaults: defaults,
                         makeEngine: { _ in engine })
    }

    private func message(_ gmailId: String = "m1", body: String = "") -> Message {
        Message(id: "a@x.com:\(gmailId)", accountId: "a@x.com", gmailId: gmailId, threadId: "a@x.com:t1",
                fromHeader: "Alice Example <alice@example.org>", toHeader: "a@x.com", ccHeader: "",
                subject: "Hi", date: Date(timeIntervalSince1970: 1_800_000_000),
                snippet: "", bodyText: body, bodyHTML: nil,
                messageIdHeader: "<m1@y.com>", referencesHeader: "", labelIds: "INBOX",
                isUnread: false, hasAttachment: true)
    }

    private let signatureAttachment = [AttachmentRow(
        id: nil, messageId: "a@x.com:m1", gmailAttachmentId: "x", filename: "signature.asc",
        mimeType: "application/pgp-signature", size: 1)]

    /// Raw messages handed out, with a count of requests.
    private final class RawSource: @unchecked Sendable {
        private let lock = NSLock()
        private let raw: Data
        private var asked: [String] = []
        init(_ raw: Data) { self.raw = raw }
        var requests: [String] {
            lock.lock(); defer { lock.unlock() }
            return asked
        }
        func fetch(_ id: String) async throws -> Data {
            lock.withLock { asked.append(id) }
            return raw
        }
    }

    func testSwitchedOffNothingIsFetchedReadOrStored() async throws {
        let engine = FakeOpenPGPEngine()
        let center = try makeCenter(enabled: false, engine: engine)
        let source = RawSource(PGPCorpus.crlf(PGPCorpus.signedSimple()))
        await center.check(message(), attachments: signatureAttachment, fetchRaw: source.fetch)
        await center.check(message(), attachments: signatureAttachment, fetchRaw: source.fetch,
                           decryptPart: true)
        XCTAssertEqual(source.requests, [])
        XCTAssertEqual(center.readings, [:])
        XCTAssertFalse(center.blocksRemoteContent(message(), candidate: true))
        let keys = try await center.keys(accountId: "a@x.com")
        XCTAssertEqual(keys, [])
        do {
            _ = try await center.importKeys(Data("k".utf8), accountId: "a@x.com", secret: false)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? PGPEngineError, .unavailable)
        }
        center.unlock(accountId: "a@x.com", passphrase: "pw")
        XCTAssertNil(center.passphrases.passphrase(accountId: "a@x.com"))
        XCTAssertEqual(engine.calls, [])
    }

    func testACandidateIsCheckedOnceAndRemoteContentWaitsForIt() async throws {
        let engine = FakeOpenPGPEngine()
        engine.detachedResults[PGPCorpus.signedPartCanonical] = [.good(signer: FakeOpenPGPEngine.alice)]
        let center = try makeCenter(enabled: true, engine: engine)
        let source = RawSource(PGPCorpus.crlf(PGPCorpus.signedSimple()))

        XCTAssertTrue(center.blocksRemoteContent(message(), candidate: true), "not checked yet")
        XCTAssertFalse(center.blocksRemoteContent(message(), candidate: false))

        await center.check(message(), attachments: signatureAttachment, fetchRaw: source.fetch)
        await center.check(message(), attachments: signatureAttachment, fetchRaw: source.fetch)
        XCTAssertEqual(source.requests, ["m1"], "one raw fetch per message")
        let reading = try XCTUnwrap(center.readings["a@x.com:m1"])
        XCTAssertEqual(reading.indicator.reason, .signed(address: "alice@example.org"))
        XCTAssertFalse(center.blocksRemoteContent(message(), candidate: true), "signed only: the policy decides")

        // Not a candidate: no request at all.
        await center.check(message("m2", body: "hello"), attachments: [], fetchRaw: source.fetch)
        XCTAssertEqual(source.requests, ["m1"])
    }

    func testAMessageWithoutOpenPGPStructureIsShownAsUsual() async throws {
        let center = try makeCenter(enabled: true)
        let source = RawSource(PGPCorpus.crlf(PGPCorpus.keyAttachment))
        await center.check(message(), attachments: signatureAttachment, fetchRaw: source.fetch)
        XCTAssertNil(center.readings["a@x.com:m1"])
        XCTAssertTrue(center.plain.contains("a@x.com:m1"))
        XCTAssertFalse(center.blocksRemoteContent(message(), candidate: true))
    }

    func testEncryptedMailAsksForThePassphraseAndKeepsItInMemory() async throws {
        let engine = FakeOpenPGPEngine()
        engine.decryption = .failure(.passphraseRequired)
        let center = try makeCenter(enabled: true, engine: engine)
        let source = RawSource(PGPCorpus.crlf(PGPCorpus.encrypted))
        let encrypted = [AttachmentRow(id: nil, messageId: "a@x.com:m1", gmailAttachmentId: "x",
                                       filename: "encrypted.asc", mimeType: "application/octet-stream",
                                       size: 1)]

        await center.check(message(), attachments: encrypted, fetchRaw: source.fetch)
        XCTAssertEqual(center.readings["a@x.com:m1"]?.body, .notice(.passphraseRequired))
        XCTAssertTrue(center.blocksRemoteContent(message(), candidate: true))
        XCTAssertFalse(center.wrongPassphrase.contains("a@x.com"), "nothing was typed yet")

        center.unlock(accountId: "a@x.com", passphrase: "wrong")
        XCTAssertNil(center.readings["a@x.com:m1"], "checked again with the passphrase")
        await center.check(message(), attachments: encrypted, fetchRaw: source.fetch)
        XCTAssertTrue(center.wrongPassphrase.contains("a@x.com"))

        engine.decryption = .success(PGPDecryptionResult(
            plaintext: Data("Content-Type: text/plain\r\n\r\nthe plan".utf8), signatures: []))
        center.unlock(accountId: "a@x.com", passphrase: "right")
        await center.check(message(), attachments: encrypted, fetchRaw: source.fetch)
        XCTAssertEqual(center.readings["a@x.com:m1"]?.body, .text("the plan"))
        XCTAssertFalse(center.wrongPassphrase.contains("a@x.com"))
        XCTAssertEqual(center.passphrases.passphrase(accountId: "a@x.com"), Data("right".utf8))

        center.forget(accountId: "a@x.com")
        XCTAssertNil(center.passphrases.passphrase(accountId: "a@x.com"))
        XCTAssertEqual(center.readings, [:])
    }

    func testChangingKeysDropsTheResultsOfThatAccount() async throws {
        let engine = FakeOpenPGPEngine()
        engine.detachedResults[PGPCorpus.signedPartCanonical] = [.good(signer: FakeOpenPGPEngine.alice)]
        engine.importable = [FakeOpenPGPEngine.alice]
        let center = try makeCenter(enabled: true, engine: engine)
        let source = RawSource(PGPCorpus.crlf(PGPCorpus.signedSimple()))
        await center.check(message(), attachments: signatureAttachment, fetchRaw: source.fetch)
        XCTAssertNotNil(center.readings["a@x.com:m1"])
        let revision = center.keysRevision
        _ = try await center.importKeys(Data("k".utf8), accountId: "a@x.com", secret: false)
        XCTAssertNil(center.readings["a@x.com:m1"])
        XCTAssertNotEqual(center.keysRevision, revision)
    }

    // MARK: - Review round 1

    /// R1 and S2: a file is inspected, not stored, and bounded.
    func testInspectStoresNothingAndKeyFilesAreBounded() async throws {
        let engine = FakeOpenPGPEngine()
        engine.importable = [FakeOpenPGPEngine.alice]
        let center = try makeCenter(enabled: true, engine: engine)
        let keys = try await center.inspect(Data("k".utf8), accountId: "a@x.com")
        XCTAssertEqual(keys, [FakeOpenPGPEngine.alice])
        XCTAssertEqual(engine.calls, [.inspectKeys(Data("k".utf8))], "nothing is imported")

        for (data, count) in [(Data(count: PGPCenter.maxKeyFileBytes + 1), 1),
                              (Data("k".utf8), PGPCenter.maxKeysPerFile + 1)] {
            engine.importable = (0..<count).map { FakeOpenPGPEngine.key(String(format: "%08X", $0), []) }
            for secret in [false, true] {
                do {
                    _ = try await center.importKeys(data, accountId: "a@x.com", secret: secret)
                    XCTFail("expected a refusal")
                } catch {
                    XCTAssertEqual(error as? PGPEngineError, .tooLarge)
                }
            }
        }
        XCTAssertFalse(engine.calls.contains { if case .importKeys = $0 { return true }; return false })
        XCTAssertFalse(engine.calls.contains { if case .importSecretKeys = $0 { return true }; return false })
    }

    /// R5: the removed account leaves Settings' memory too.
    func testForgettingAnAccountClearsTheSettingsChoice() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PGPCenterTests-\(UUID().uuidString)"))
        let center = try makeCenter(enabled: false, defaults: defaults)
        defaults.set("b@x.com", forKey: PGPCenter.settingsAccountKey)
        center.forget(accountId: "a@x.com")
        XCTAssertEqual(defaults.string(forKey: PGPCenter.settingsAccountKey), "b@x.com")
        center.forget(accountId: "b@x.com")
        XCTAssertNil(defaults.string(forKey: PGPCenter.settingsAccountKey))
    }

    /// R5: a removed account's secret keys go, and the launch sweep runs,
    /// whatever the switch says (these take no switch at all).
    func testSecretKeysOfARemovedAccountGoWhateverTheSwitch() async throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        let secrets = MemorySecretKeys()
        let a = PGPSecretKeyOwner(accountId: "a@x.com", key: PGPKeyReference(fingerprint: "AAAA"))
        let b = PGPSecretKeyOwner(accountId: "b@x.com", key: PGPKeyReference(fingerprint: "BBBB"))
        try secrets.setSecretKey(Data("x".utf8), of: a)
        try secrets.setSecretKey(Data("y".utf8), of: b)
        PGPCenter.removeSecretKeys(accountId: "a@x.com", secrets: secrets)
        XCTAssertEqual(Array(secrets.stored.keys), [b])
        await PGPCenter.sweepSecretKeys(database: q, secrets: secrets)
        XCTAssertEqual(secrets.stored, [:], "no row lists b's key")
    }

    /// S4: a lock or sleep forgets passphrases and decrypted text.
    func testLockOrSleepForgetsPassphrasesAndReadings() async throws {
        let engine = FakeOpenPGPEngine()
        engine.detachedResults[PGPCorpus.signedPartCanonical] = [.good(signer: FakeOpenPGPEngine.alice)]
        let center = try makeCenter(enabled: true, engine: engine)
        await center.check(message(), attachments: signatureAttachment,
                           fetchRaw: RawSource(PGPCorpus.crlf(PGPCorpus.signedSimple())).fetch)
        center.unlock(accountId: "a@x.com", passphrase: "pw")
        await center.check(message(), attachments: signatureAttachment,
                           fetchRaw: RawSource(PGPCorpus.crlf(PGPCorpus.signedSimple())).fetch)
        XCTAssertNotNil(center.readings["a@x.com:m1"])
        center.lockedOrAsleep()
        XCTAssertNil(center.passphrases.passphrase(accountId: "a@x.com"))
        XCTAssertEqual(center.readings, [:])
    }

    /// R3, end to end: the card's From decides the signed mark.
    func testASignatureForAnotherAddressThanTheCardShowsIsNotSigned() async throws {
        let engine = FakeOpenPGPEngine()
        engine.detachedResults[PGPCorpus.signedPartCanonical] = [.good(signer: FakeOpenPGPEngine.alice)]
        let center = try makeCenter(enabled: true, engine: engine)
        var shown = message()
        shown.fromHeader = "Boss <boss@corp.com>"
        await center.check(shown, attachments: signatureAttachment,
                           fetchRaw: RawSource(PGPCorpus.crlf(PGPCorpus.signedSimple())).fetch)
        let reading = try XCTUnwrap(center.readings["a@x.com:m1"])
        XCTAssertEqual(reading.indicator.reason, .signerIsNotSender)
        XCTAssertEqual(reading.body, .original)
    }
}
