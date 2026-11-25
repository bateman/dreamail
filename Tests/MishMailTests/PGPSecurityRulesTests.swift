import XCTest

/// What the security bar may say and how the view must render (step 4B).
/// Pure rules over engine results: never "signed" for part of a message,
/// never a positive mark the sender can produce without the signer's key,
/// no decrypted content without an integrity check, and remote content
/// blocked wherever something was encrypted.
final class PGPSecurityRulesTests: XCTestCase {
    private let alice = FakeOpenPGPEngine.alice
    private let mallory = FakeOpenPGPEngine.mallory
    private let from = "Alice Example <alice@example.org>"

    private func signed(_ results: [PGPSignatureResult], whole: Bool = true,
                        from: String? = nil) -> PGPIndicator {
        PGPSecurityRules.indicator(for: PGPMessageSecurity(
            encryption: .notEncrypted, signature: .checked(results, coversWholeMessage: whole),
            fromHeader: from ?? self.from))
    }

    private func decrypted(whole: Bool = true, signatures: [PGPSignatureResult] = []) -> PGPIndicator {
        PGPSecurityRules.indicator(for: PGPMessageSecurity(
            encryption: .decrypted(PGPDecryptionResult(plaintext: Data("secret".utf8),
                                                       signatures: signatures),
                                   coversWholeMessage: whole),
            signature: .unsigned, fromHeader: from))
    }

    private func encryption(_ state: PGPMessageSecurity.Encryption) -> PGPIndicator {
        PGPSecurityRules.indicator(for: PGPMessageSecurity(encryption: state, signature: .unsigned,
                                                           fromHeader: from))
    }

    func testNothingToSayForAPlainMessage() {
        let plain = PGPSecurityRules.indicator(for: PGPMessageSecurity(
            encryption: .notEncrypted, signature: .unsigned, fromHeader: from))
        XCTAssertEqual(plain, PGPIndicator(tone: .none, reason: .none, showsSignedMark: false,
                                           showsLock: false, render: .plain))
    }

    func testGoodSignatureByTheSenderOverTheWholeMessage() {
        let indicator = signed([.good(signer: alice)])
        XCTAssertEqual(indicator.reason, .signed(address: "alice@example.org"))
        XCTAssertEqual(indicator.tone, .positive)
        XCTAssertTrue(indicator.showsSignedMark)
        XCTAssertFalse(indicator.showsLock)
        XCTAssertEqual(indicator.render, .plain, "signing alone changes nothing in rendering")
        XCTAssertEqual(signed([.good(signer: alice)], from: "ALICE@Example.ORG").reason,
                       .signed(address: "alice@example.org"))
    }

    func testPartialSignatureIsNeverSigned() {
        for results: [PGPSignatureResult] in [[.good(signer: alice)], [.unknownKey(keyID: "X")]] {
            let indicator = signed(results, whole: false)
            XCTAssertEqual(indicator.reason, .partlySigned)
            XCTAssertEqual(indicator.tone, .warning)
            XCTAssertFalse(indicator.showsSignedMark)
        }
    }

    func testGoodSignatureBySomeoneElseIsAWarning() {
        // Mallory signs with her own key and puts Alice in From.
        XCTAssertEqual(signed([.good(signer: mallory)]).reason, .signerIsNotSender)
        XCTAssertFalse(signed([.good(signer: mallory)]).showsSignedMark)
        // A display name that looks like Alice's address is not her address.
        XCTAssertEqual(signed([.good(signer: alice)],
                              from: "\"alice@example.org\" <mallory@example.net>").reason,
                       .signerIsNotSender)
        // Several mailboxes in From: a signature cannot vouch for "the sender".
        XCTAssertEqual(signed([.good(signer: alice)],
                              from: "alice@example.org, mallory@example.net").reason,
                       .signerIsNotSender)
    }

    func testAnyBadSignatureIsAnError() {
        for results: [PGPSignatureResult] in [[.bad], [.good(signer: alice), .bad], []] {
            let indicator = signed(results)
            XCTAssertEqual(indicator.reason, .badSignature, "\(results)")
            XCTAssertEqual(indicator.tone, .error)
            XCTAssertFalse(indicator.showsSignedMark)
        }
    }

    func testUnknownExpiredAndUnsupported() {
        XCTAssertEqual(signed([.unknownKey(keyID: "0x1234")]),
                       PGPIndicator(tone: .neutral, reason: .unknownKey(keyID: "0x1234"),
                                    showsSignedMark: false, showsLock: false, render: .plain))
        XCTAssertEqual(signed([.keyNotValid(signer: alice)]).reason, .keyNotValid)
        XCTAssertEqual(signed([.unsupported]).reason, .unsupported)
        XCTAssertEqual(signed([.unknownKey(keyID: "X"), .good(signer: alice)]).reason,
                       .signed(address: "alice@example.org"))

        let unchecked = PGPSecurityRules.indicator(for: PGPMessageSecurity(
            encryption: .notEncrypted, signature: .notChecked(.unavailable), fromHeader: from))
        XCTAssertEqual(unchecked.reason, .notChecked)
        XCTAssertFalse(unchecked.showsSignedMark)
    }

    func testWholeEncryption() {
        let inline = PGPRenderPolicy(decryptedContent: .inline, blocksRemoteContent: true)
        XCTAssertEqual(decrypted(), PGPIndicator(tone: .positive, reason: .encrypted,
                                                 showsSignedMark: false, showsLock: true,
                                                 render: inline))
        let both = decrypted(signatures: [.good(signer: alice)])
        XCTAssertEqual(both.reason, .encryptedAndSigned(address: "alice@example.org"))
        XCTAssertTrue(both.showsLock)
        XCTAssertTrue(both.showsSignedMark)
        XCTAssertEqual(both.render, inline)

        let badInside = decrypted(signatures: [.bad])
        XCTAssertEqual(badInside.reason, .badSignature)
        XCTAssertTrue(badInside.showsLock, "still encrypted")
        XCTAssertFalse(badInside.showsSignedMark)
        XCTAssertEqual(badInside.render, inline)
    }

    /// EFAIL direct exfiltration: an encrypted part inside a message the
    /// attacker built. Not decrypted unless asked; when asked, shown apart,
    /// and remote content stays blocked for the whole message.
    func testPartialEncryptionIsOnRequestSeparateAndBlocksRemoteContent() {
        let notYet = encryption(.notDecrypted)
        XCTAssertEqual(notYet, PGPIndicator(tone: .warning, reason: .partlyEncrypted,
                                            showsSignedMark: false, showsLock: false,
                                            render: PGPRenderPolicy(decryptedContent: .onRequest,
                                                                    blocksRemoteContent: true)))

        let asked = decrypted(whole: false, signatures: [.good(signer: alice)])
        XCTAssertEqual(asked.reason, .partlyEncrypted)
        XCTAssertFalse(asked.showsLock)
        XCTAssertFalse(asked.showsSignedMark)
        XCTAssertEqual(asked.render, PGPRenderPolicy(decryptedContent: .separateView,
                                                     blocksRemoteContent: true))
    }

    func testFailuresWithholdContent() {
        let withheld = PGPRenderPolicy(decryptedContent: .withheld, blocksRemoteContent: true)
        let noIntegrity = encryption(.failed(.notIntegrityProtected))
        XCTAssertEqual(noIntegrity.reason, .notIntegrityProtected)
        XCTAssertEqual(noIntegrity.tone, .error)
        XCTAssertEqual(noIntegrity.render, withheld)

        for error in [PGPEngineError.noSecretKey, .passphraseRequired, .malformed, .unsupported] {
            let failed = encryption(.failed(error))
            XCTAssertEqual(failed.reason, .decryptionFailed, "\(error)")
            XCTAssertEqual(failed.tone, .error)
            XCTAssertEqual(failed.render, withheld)
            XCTAssertFalse(failed.showsLock)
        }
    }

    /// A build without a library is not an error the sender caused.
    func testNoLibraryIsNeutral() {
        let indicator = encryption(.failed(.unavailable))
        XCTAssertEqual(indicator.reason, .decryptionUnavailable)
        XCTAssertEqual(indicator.tone, .neutral)
        XCTAssertEqual(indicator.render.decryptedContent, .withheld)
        XCTAssertTrue(indicator.render.blocksRemoteContent)
    }

    func testSenderAndSignerAddresses() {
        XCTAssertEqual(PGPSecurityRules.senderAddress("Alice <Alice@Example.org>"), "alice@example.org")
        XCTAssertNil(PGPSecurityRules.senderAddress(""))
        XCTAssertNil(PGPSecurityRules.senderAddress("Undisclosed"))
        XCTAssertEqual(PGPSecurityRules.signerAddresses(FakeOpenPGPEngine.key(
            "F", ["A <a@example.org>", "b@example.org", "No address"])),
                       ["a@example.org", "b@example.org"])
    }
}
