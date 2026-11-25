import XCTest

/// What the message view shows for an OpenPGP message (step 4B): the body
/// that replaces the original, the header summary, the signature details,
/// and which stored messages are worth a raw fetch. Inline cleartext
/// signatures go through the engine like PGP/MIME ones.
final class PGPDisplayTests: XCTestCase {

    private func indicator(_ security: PGPMessageSecurity) -> PGPIndicator {
        PGPSecurityRules.indicator(for: security)
    }

    private func display(_ security: PGPMessageSecurity) -> PGPBodyDisplay {
        PGPDisplay.body(for: security, indicator: indicator(security))
    }

    private let from = "Alice Example <alice@example.org>"

    // MARK: - Inline cleartext

    func testInlineCleartextGoesToTheEngineAndShowsOnlyItsText() async throws {
        let engine = FakeOpenPGPEngine()
        engine.cleartext = .success(PGPCleartextResult(
            signedText: Data("Hello, this is a cleartext-signed message.\n-- dash-escaped line\n".utf8),
            signatures: [.good(signer: FakeOpenPGPEngine.alice)]))
        let checked = await PGPInspection.security(
            ofRaw: PGPCorpus.crlf(PGPCorpus.inlineSigned), engine: engine, enabled: true)
        let security = try XCTUnwrap(checked)
        XCTAssertEqual(indicator(security).reason, .signed(address: "alice@example.org"))
        XCTAssertEqual(display(security),
                       .text("Hello, this is a cleartext-signed message.\n-- dash-escaped line\n"),
                       "the engine's text, never the stored body")
        guard case .verifyCleartext(let sent) = engine.calls.first else {
            return XCTFail("the engine was not asked")
        }
        XCTAssertTrue(String(decoding: sent, as: UTF8.self).hasPrefix("-----BEGIN PGP SIGNED MESSAGE-----"))
    }

    func testInlineCleartextFailuresAreNeverValid() async throws {
        for result: Result<PGPCleartextResult, PGPEngineError> in [
            .success(PGPCleartextResult(signedText: Data("x".utf8), signatures: [.bad])),
            .success(PGPCleartextResult(signedText: Data("x".utf8), signatures: [.unknownKey(keyID: "1234")])),
            .failure(.malformed),
        ] {
            let engine = FakeOpenPGPEngine()
            engine.cleartext = result
            let checked = await PGPInspection.security(
                ofRaw: PGPCorpus.crlf(PGPCorpus.inlineSigned), engine: engine, enabled: true)
            let security = try XCTUnwrap(checked)
            XCTAssertFalse(indicator(security).showsSignedMark)
            XCTAssertEqual(display(security), .original)
        }
    }

    func testInlineCleartextWithTextAroundItIsOnlyPartlySigned() async throws {
        let wrapped = PGPCorpus.inlineSigned + "\n\n-- \nList footer anyone could add\n"
        let engine = FakeOpenPGPEngine()
        engine.cleartext = .success(PGPCleartextResult(signedText: Data("x".utf8),
                                                       signatures: [.good(signer: FakeOpenPGPEngine.alice)]))
        let checked = await PGPInspection.security(
            ofRaw: PGPCorpus.crlf(wrapped), engine: engine, enabled: true)
        let security = try XCTUnwrap(checked)
        XCTAssertEqual(indicator(security).reason, .partlySigned)
        XCTAssertEqual(display(security), .original)
    }

    func testSwitchedOffInlineCleartextIsNotRead() async {
        let engine = FakeOpenPGPEngine()
        let none = await PGPInspection.security(ofRaw: PGPCorpus.crlf(PGPCorpus.inlineSigned),
                                                engine: engine, enabled: false)
        XCTAssertNil(none)
        XCTAssertEqual(engine.calls, [])
    }

    // MARK: - Body

    func testAGoodPGPMIMESignatureShowsTheSignedPartsText() {
        let signed = Data("Content-Type: text/plain; charset=utf-8\r\n\r\nHello Bob, caf\u{e9}.\r\n".utf8)
        let security = PGPMessageSecurity(
            encryption: .notEncrypted,
            signature: .checked([.good(signer: FakeOpenPGPEngine.alice)], coversWholeMessage: true),
            fromHeader: from, signedContent: signed)
        XCTAssertEqual(display(security), .text("Hello Bob, caf\u{e9}.\r\n"))
    }

    /// Only the decrypted text is shown, as text: an HTML part becomes text
    /// and nothing is concatenated with the surrounding message (EFAIL).
    func testDecryptedHTMLIsShownAsTextOnly() {
        let plaintext = Data("""
            Content-Type: multipart/alternative; boundary="b"\r
            \r
            --b\r
            Content-Type: text/html\r
            \r
            <p>Secret <img src="https://evil.example/x?">plan</p>\r
            --b--\r

            """.utf8)
        let security = PGPMessageSecurity(
            encryption: .decrypted(PGPDecryptionResult(plaintext: plaintext, signatures: []),
                                   coversWholeMessage: true),
            signature: .unsigned, fromHeader: from)
        let indicator = indicator(security)
        XCTAssertTrue(indicator.render.blocksRemoteContent)
        guard case .text(let text) = display(security) else { return XCTFail("not text") }
        XCTAssertTrue(text.contains("Secret"))
        XCTAssertFalse(text.contains("<img"), "no HTML reaches the view")
    }

    func testFailuresShowANoticeNeverArmor() {
        let cases: [(PGPEngineError, PGPBodyNotice)] = [
            (.unavailable, .unavailable), (.noSecretKey, .noSecretKey),
            (.passphraseRequired, .passphraseRequired),
            (.notIntegrityProtected, .notIntegrityProtected),
            (.malformed, .cannotDecrypt), (.tooLarge, .cannotDecrypt), (.unsupported, .cannotDecrypt),
        ]
        for (error, notice) in cases {
            let security = PGPMessageSecurity(encryption: .failed(error), signature: .unsigned,
                                              fromHeader: from)
            XCTAssertEqual(display(security), .notice(notice))
            XCTAssertFalse(notice.text.contains("BEGIN PGP"))
        }
    }

    func testDecryptedWithoutTextSaysSo() {
        let security = PGPMessageSecurity(
            encryption: .decrypted(PGPDecryptionResult(
                plaintext: Data("Content-Type: image/png\r\n\r\nxx".utf8), signatures: []),
                                   coversWholeMessage: true),
            signature: .unsigned, fromHeader: from)
        XCTAssertEqual(display(security), .notice(.noReadableText))
    }

    func testAPartDecryptedOnRequestIsShownApart() {
        let security = PGPMessageSecurity(
            encryption: .decrypted(PGPDecryptionResult(plaintext: Data("Content-Type: text/plain\r\n\r\npart".utf8),
                                                       signatures: []), coversWholeMessage: false),
            signature: .unsigned, fromHeader: from)
        XCTAssertEqual(display(security), .original)
        XCTAssertEqual(PGPDisplay.separatePart(for: security), "part")
        XCTAssertEqual(indicator(security).render.decryptedContent, .separateView)
    }

    func testAnAttachmentIsNotTakenForTheText() {
        let entity = Data("""
            Content-Type: multipart/mixed; boundary="m"\r
            \r
            --m\r
            Content-Type: text/plain\r
            Content-Disposition: attachment; filename="notes.txt"\r
            \r
            attached\r
            --m\r
            Content-Type: text/plain\r
            \r
            the message\r
            --m--\r

            """.utf8)
        XCTAssertEqual(PGPDisplay.readableText(ofEntity: entity), "the message")
    }

    // MARK: - Header and details

    /// An unknown key is "cannot verify", not an error; a bad signature is
    /// never shown as valid.
    func testSummaryWording() {
        let unknown = PGPMessageSecurity(encryption: .notEncrypted,
                                         signature: .checked([.unknownKey(keyID: "ABCD")], coversWholeMessage: true),
                                         fromHeader: from)
        XCTAssertEqual(indicator(unknown).tone, .neutral)
        XCTAssertEqual(PGPDisplay.summary(indicator(unknown))?.title, "Can’t verify the signature: unknown key")

        let bad = PGPMessageSecurity(encryption: .notEncrypted,
                                     signature: .checked([.good(signer: FakeOpenPGPEngine.alice), .bad],
                                                         coversWholeMessage: true),
                                     fromHeader: from)
        XCTAssertEqual(indicator(bad).tone, .error)
        XCTAssertEqual(PGPDisplay.summary(indicator(bad))?.title, "Invalid signature")
        XCTAssertEqual(display(bad), .original)

        let plain = PGPMessageSecurity(encryption: .notEncrypted, signature: .unsigned, fromHeader: from)
        XCTAssertNil(PGPDisplay.summary(indicator(plain)))
    }

    func testSignatureLines() {
        var expired = FakeOpenPGPEngine.alice
        expired = PGPKeySummary(key: expired.key, userIDs: expired.userIDs, hasSecretKey: false,
                                created: nil, expires: nil, validity: .expired)
        let security = PGPMessageSecurity(
            encryption: .notEncrypted,
            signature: .checked([.good(signer: FakeOpenPGPEngine.alice), .keyNotValid(signer: expired),
                                 .unknownKey(keyID: "1234ABCD"), .bad, .unsupported],
                                coversWholeMessage: true),
            fromHeader: from)
        XCTAssertEqual(PGPDisplay.signatureLines(security).map(\.status),
                       [.valid, .expired, .unknownKey, .invalid, .unsupported])
        XCTAssertEqual(PGPDisplay.signatureLines(security)[2].keyIdentifier, "1234ABCD")
        XCTAssertEqual(PGPDisplay.grouped("AAAABBBBCCCCDD"), "AAAA BBBB CCCC DD")
    }

    // MARK: - Candidates

    func testCandidates() {
        func row(_ name: String, _ type: String) -> AttachmentRow {
            AttachmentRow(id: nil, messageId: "a:m", gmailAttachmentId: "x", filename: name,
                          mimeType: type, size: 1)
        }
        XCTAssertTrue(PGPDisplay.isCandidate(bodyText: "", attachments: [row("signature.asc", "application/pgp-signature")],
                                             enabled: true))
        XCTAssertTrue(PGPDisplay.isCandidate(bodyText: "", attachments: [row("encrypted.asc", "application/octet-stream")],
                                             enabled: true))
        XCTAssertTrue(PGPDisplay.isCandidate(bodyText: "x\n-----BEGIN PGP SIGNED MESSAGE-----\n", attachments: [],
                                             enabled: true))
        XCTAssertFalse(PGPDisplay.isCandidate(bodyText: "hello", attachments: [row("a.pdf", "application/pdf")],
                                              enabled: true))
        XCTAssertFalse(PGPDisplay.isCandidate(bodyText: "-----BEGIN PGP SIGNED MESSAGE-----",
                                              attachments: [row("signature.asc", "application/pgp-signature")],
                                              enabled: false), "off: nothing is looked at")
    }
}
