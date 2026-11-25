import XCTest
import GRDB

/// The app's OpenPGP center (step 4B): off, it reads, fetches and stores
/// nothing; on, it checks a candidate message once, keeps the result in
/// memory, asks for a passphrase, and keeps remote content blocked until a
/// message is known.
@MainActor
final class PGPCenterTests: XCTestCase {

    private func makeCenter(enabled: Bool, engine: FakeOpenPGPEngine = FakeOpenPGPEngine())
        throws -> PGPCenter {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return PGPCenter(database: q, enabled: enabled, secrets: MemorySecretKeys(),
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
}
