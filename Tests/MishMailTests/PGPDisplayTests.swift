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
            (.malformed, .unsupportedFormat), (.unsupported, .unsupportedFormat), (.tooLarge, .tooLarge),
        ]
        for (error, notice) in cases {
            let security = PGPMessageSecurity(encryption: .failed(error), signature: .unsigned,
                                              fromHeader: from)
            XCTAssertEqual(display(security), .notice(notice))
            XCTAssertFalse(notice.text.contains("BEGIN PGP"))
        }
        // An attacker on the path can cause any of these: none reads as
        // more harmless than a failed integrity check.
        let unauthenticated: [PGPBodyNotice] = [.notIntegrityProtected, .unsupportedFormat, .tooLarge]
        XCTAssertEqual(Set(unauthenticated.map(\.text)), ["This message could not be decrypted."])
        for notice in unauthenticated {
            let detail = notice.detail?.lowercased() ?? ""
            for hint in ["update", "unencrypted", "resend", "harmless", "version"] {
                XCTAssertFalse(detail.contains(hint), "\(notice): \(hint)")
            }
        }
        let tones = [PGPEngineError.notIntegrityProtected, .malformed, .unsupported, .tooLarge].map {
            PGPSecurityRules.indicator(for: PGPMessageSecurity(encryption: .failed($0), signature: .unsigned,
                                                               fromHeader: from)).tone
        }
        XCTAssertEqual(Set(tones), [.error], "one colour for every failure")
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

    // MARK: - Review round 1

    /// R3: the signed mark only when the From the card shows names the
    /// address the signature vouches for.
    func testTheSignedMarkNeedsTheDisplayedSender() {
        let signed = PGPIndicator(tone: .positive, reason: .signed(address: "alice@example.org"),
                                  showsSignedMark: true, showsLock: false, render: .plain)
        for shown in ["Alice <alice@example.org>", "ALICE@Example.ORG", "\"Alice, Inc.\" <alice@example.org>"] {
            XCTAssertEqual(PGPDisplay.bound(signed, displayedFrom: shown), signed, shown)
        }
        for shown in ["Boss <boss@corp.com>", "\"alice@example.org\" <mallory@evil.example>",
                      "=?utf-8?q?alice@example.org?= <mallory@evil.example>",
                      "Alice <alice@example.org>, Boss <boss@corp.com>", ""] {
            let bound = PGPDisplay.bound(signed, displayedFrom: shown)
            XCTAssertEqual(bound.reason, .signerIsNotSender, shown)
            XCTAssertFalse(bound.showsSignedMark, shown)
        }
        let encrypted = PGPIndicator(tone: .positive, reason: .encryptedAndSigned(address: "alice@example.org"),
                                     showsSignedMark: true, showsLock: true,
                                     render: PGPRenderPolicy(decryptedContent: .inline, blocksRemoteContent: true))
        let bound = PGPDisplay.bound(encrypted, displayedFrom: "Boss <boss@corp.com>")
        XCTAssertTrue(bound.showsLock, "still encrypted")
        XCTAssertEqual(bound.render, encrypted.render)
        XCTAssertFalse(bound.showsSignedMark)
    }

    /// R4: plaintext above the cap is never handed to a `Text`.
    func testLongDecryptedTextIsNotShown() {
        let long = String(repeating: "a", count: PGPDisplay.maxShownBytes + 1)
        for body in [long, "<p>" + String(repeating: "a", count: 4 * PGPDisplay.maxShownBytes) + "</p>"] {
            let type = body.hasPrefix("<p>") ? "text/html" : "text/plain"
            let security = PGPMessageSecurity(
                encryption: .decrypted(PGPDecryptionResult(
                    plaintext: Data("Content-Type: \(type)\r\n\r\n\(body)".utf8), signatures: []),
                                       coversWholeMessage: true),
                signature: .unsigned, fromHeader: from)
            XCTAssertEqual(display(security), .notice(.tooLongToShow))
        }
        let cleartext = PGPMessageSecurity(
            encryption: .notEncrypted,
            signature: .checked([.good(signer: FakeOpenPGPEngine.alice)], coversWholeMessage: true),
            fromHeader: from, signedText: Data(long.utf8))
        XCTAssertEqual(display(cleartext), .notice(.tooLongToShow))
    }

    /// R1: an address another stored key already claims is flagged.
    func testAddressesClaimedByAnotherStoredKey() {
        let boss = FakeOpenPGPEngine.key("CCCC", ["Boss <boss@corp.com>"])
        let mallory = FakeOpenPGPEngine.key("DDDD", ["Mallory <mallory@evil.example>", "<BOSS@corp.com>"])
        XCTAssertEqual(PGPDisplay.addressesClaimedElsewhere([mallory], stored: [boss]),
                       [mallory.key: ["boss@corp.com"]])
        XCTAssertEqual(PGPDisplay.addressesClaimedElsewhere([boss], stored: [boss]), [:], "the same key is no clash")
        XCTAssertEqual(PGPDisplay.addressesClaimedElsewhere([mallory], stored: []), [:])
    }
}
