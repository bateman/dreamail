import XCTest

/// What the security bar may say (step 4B). Pure rules over engine results:
/// never "signed" for part of a message, never a positive mark the sender
/// can produce without the signer's key, and no decrypted content without
/// an integrity check.
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

    private func decrypted(integrity: Bool = true, whole: Bool = true,
                           signatures: [PGPSignatureResult] = []) -> PGPIndicator {
        PGPSecurityRules.indicator(for: PGPMessageSecurity(
            encryption: .decrypted(PGPDecryptionResult(plaintext: Data("secret".utf8),
                                                       integrityProtected: integrity,
                                                       signatures: signatures),
                                   coversWholeMessage: whole),
            signature: .unsigned, fromHeader: from))
    }

    func testNothingToSayForAPlainMessage() {
        let plain = PGPSecurityRules.indicator(for: PGPMessageSecurity(
            encryption: .notEncrypted, signature: .unsigned, fromHeader: from))
        XCTAssertEqual(plain, PGPIndicator(tone: .none, reason: .none, showsSignedMark: false,
                                           showsLock: false, mayShowDecryptedContent: true))
    }

    func testGoodSignatureByTheSenderOverTheWholeMessage() {
        let indicator = signed([.good(signer: alice)])
        XCTAssertEqual(indicator.reason, .signed(address: "alice@example.org"))
        XCTAssertEqual(indicator.tone, .positive)
        XCTAssertTrue(indicator.showsSignedMark)
        XCTAssertFalse(indicator.showsLock)
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
                                    showsSignedMark: false, showsLock: false,
                                    mayShowDecryptedContent: true))
        XCTAssertEqual(signed([.keyNotValid(signer: alice)]).reason, .keyNotValid)
        XCTAssertEqual(signed([.unsupported]).reason, .unsupported)
        XCTAssertEqual(signed([.unknownKey(keyID: "X"), .good(signer: alice)]).reason,
                       .signed(address: "alice@example.org"))

        let unchecked = PGPSecurityRules.indicator(for: PGPMessageSecurity(
            encryption: .notEncrypted, signature: .notChecked(.unavailable), fromHeader: from))
        XCTAssertEqual(unchecked.reason, .notChecked)
        XCTAssertFalse(unchecked.showsSignedMark)
    }

    func testEncryption() {
        XCTAssertEqual(decrypted(), PGPIndicator(tone: .positive, reason: .encrypted,
                                                 showsSignedMark: false, showsLock: true,
                                                 mayShowDecryptedContent: true))
        let both = decrypted(signatures: [.good(signer: alice)])
        XCTAssertEqual(both.reason, .encryptedAndSigned(address: "alice@example.org"))
        XCTAssertTrue(both.showsLock)
        XCTAssertTrue(both.showsSignedMark)

        let badInside = decrypted(signatures: [.bad])
        XCTAssertEqual(badInside.reason, .badSignature)
        XCTAssertTrue(badInside.showsLock, "still encrypted")
        XCTAssertFalse(badInside.showsSignedMark)
    }

    func testPartialEncryptionShowsNoLockAndNoSignature() {
        let indicator = decrypted(whole: false, signatures: [.good(signer: alice)])
        XCTAssertEqual(indicator.reason, .partlyEncrypted)
        XCTAssertFalse(indicator.showsLock)
        XCTAssertFalse(indicator.showsSignedMark)
    }

    /// EFAIL: plaintext without an integrity check is not shown at all.
    func testNoIntegrityProtectionWithholdsTheContent() {
        let indicator = decrypted(integrity: false, signatures: [.good(signer: alice)])
        XCTAssertEqual(indicator.reason, .notIntegrityProtected)
        XCTAssertEqual(indicator.tone, .error)
        XCTAssertFalse(indicator.mayShowDecryptedContent)
        XCTAssertFalse(indicator.showsLock)
        XCTAssertFalse(indicator.showsSignedMark)
    }

    func testDecryptionFailure() {
        let indicator = PGPSecurityRules.indicator(for: PGPMessageSecurity(
            encryption: .failed(.noSecretKey), signature: .unsigned, fromHeader: from))
        XCTAssertEqual(indicator.reason, .decryptionFailed)
        XCTAssertFalse(indicator.mayShowDecryptedContent)
    }

    func testDecryptedContentPolicyIsFixed() {
        XCTAssertFalse(PGPRenderPolicy.decrypted.allowsRemoteContent)
        XCTAssertFalse(PGPRenderPolicy.decrypted.allowsHTML)
        XCTAssertFalse(PGPRenderPolicy.decrypted.mayLeaveTheMessageView)
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
