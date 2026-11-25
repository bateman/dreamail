import XCTest

/// The path from a raw message to the engine and back (step 4B), and the
/// build switch that keeps all of it off.
final class PGPInspectionTests: XCTestCase {

    private func security(_ message: String, _ engine: any OpenPGPEngine,
                          decryptPartOnRequest: Bool = false) async -> PGPMessageSecurity? {
        await PGPInspection.security(ofRaw: PGPCorpus.crlf(message), engine: engine, enabled: true,
                                     decryptPartOnRequest: decryptPartOnRequest)
    }

    private func reason(_ security: PGPMessageSecurity?) throws -> PGPIndicator.Reason {
        PGPSecurityRules.indicator(for: try XCTUnwrap(security)).reason
    }

    private func aliceSigned() -> FakeOpenPGPEngine {
        let engine = FakeOpenPGPEngine()
        engine.detachedResults[PGPCorpus.signedPartCanonical] = [.good(signer: FakeOpenPGPEngine.alice)]
        return engine
    }

    // MARK: - Signatures

    func testEngineReceivesExactlyTheCanonicalSignedBytes() async throws {
        let engine = aliceSigned()
        for raw in [PGPCorpus.crlf(PGPCorpus.signedSimple()), PGPCorpus.lf(PGPCorpus.signedSimple())] {
            let result = await PGPInspection.security(ofRaw: raw, engine: engine, enabled: true)
            XCTAssertEqual(try reason(result), .signed(address: "alice@example.org"))
            XCTAssertEqual(result?.fromHeader, "Alice Example <alice@example.org>", "From from the raw bytes")
            XCTAssertEqual(result?.signedContent, PGPCorpus.signedPartCanonical,
                           "the only content that may be shown as signed")
        }
        XCTAssertEqual(engine.calls.count, 2)
        for case .verifyDetached(let signedData, let signature) in engine.calls {
            XCTAssertEqual(signedData, PGPCorpus.signedPartCanonical)
            XCTAssertTrue(String(decoding: signature, as: UTF8.self)
                .hasPrefix("-----BEGIN PGP SIGNATURE-----"))
        }
    }

    /// One changed byte in the signed part: the engine sees different bytes
    /// and the message is not signed.
    func testAChangedSignedPartIsNotSigned() async throws {
        let tampered = PGPCorpus.signedSimple().replacingOccurrences(of: "Hello Bob", with: "Hello Bab")
        let result1 = await security(tampered, aliceSigned())
        XCTAssertEqual(try reason(result1), .badSignature)
    }

    /// The sender is whoever the raw message names, whatever a caller thinks.
    func testFromComesFromTheRawMessage() async throws {
        let mallory = PGPCorpus.signedSimple().replacingOccurrences(
            of: "From: Alice Example <alice@example.org>", with: "From: Mallory <mallory@example.net>")
        let result2 = await security(mallory, aliceSigned())
        XCTAssertEqual(try reason(result2), .signerIsNotSender)
    }

    /// Two From headers: which one is "the sender" depends on the reader.
    func testTwoFromHeadersAreNotChecked() async throws {
        let engine = aliceSigned()
        let result = await security(PGPCorpus.signedAmbiguous("two-froms"), engine)
        XCTAssertEqual(result?.signature, .notChecked(.malformed))
        XCTAssertFalse(PGPSecurityRules.indicator(for: try XCTUnwrap(result)).showsSignedMark)
        XCTAssertEqual(engine.calls, [])
    }

    func testAmbiguousOrTruncatedStructuresAreNotChecked() async throws {
        let engine = aliceSigned()
        for message in ["two-content-types", "two-boundaries", "rfc2231-boundary"]
            .map(PGPCorpus.signedAmbiguous) + [PGPCorpus.signedTooDeep(depth: RawMIME.maxDepth + 2)] {
            let result = await security(message, engine)
            XCTAssertEqual(result?.signature, .notChecked(.malformed))
        }
        XCTAssertEqual(engine.calls, [])
    }

    func testListFooterMakesAGoodSignaturePartial() async throws {
        let engine = FakeOpenPGPEngine()
        let signedPart = Data("Content-Type: text/plain; charset=utf-8\r\n\r\nThe signed post.".utf8)
        engine.detachedResults[signedPart] = [.good(signer: FakeOpenPGPEngine.alice)]
        let result = await security(PGPCorpus.listWrapped, engine)
        let indicator = PGPSecurityRules.indicator(for: try XCTUnwrap(result))
        XCTAssertEqual(indicator.reason, .partlySigned)
        XCTAssertFalse(indicator.showsSignedMark)
        XCTAssertEqual(engine.calls, [.verifyDetached(signedData: signedPart,
                                                      signature: PGPCorpus.crlf(PGPCorpus.fakeSignature))])
    }

    func testWithoutALibraryNothingIsClaimed() async throws {
        let result = await security(PGPCorpus.signedSimple(), UnavailableOpenPGPEngine())
        XCTAssertEqual(result?.signature, .notChecked(.unavailable))
        XCTAssertFalse(PGPSecurityRules.indicator(for: try XCTUnwrap(result)).showsSignedMark)

        let encrypted = await security(PGPCorpus.encrypted, UnavailableOpenPGPEngine())
        XCTAssertEqual(try reason(encrypted), .decryptionUnavailable)
    }

    func testMalformedAndPlainMessages() async {
        let engine = FakeOpenPGPEngine()
        let malformed = await security(PGPCorpus.malformedSigned, engine)
        XCTAssertEqual(malformed?.signature, .notChecked(.malformed))
        for message in [PGPCorpus.plain, PGPCorpus.smimeSigned, PGPCorpus.plainLookingSigned] {
            let none = await security(message, engine)
            XCTAssertNil(none)
        }
        XCTAssertEqual(engine.calls, [])
    }

    // MARK: - Encryption

    func testEncryptedMessageGoesToDecrypt() async throws {
        let engine = FakeOpenPGPEngine()
        engine.decryption = .success(PGPDecryptionResult(plaintext: Data("hi".utf8), signatures: []))
        let result3 = await security(PGPCorpus.encrypted, engine)
        XCTAssertEqual(try reason(result3), .encrypted)
        XCTAssertEqual(engine.calls, [.decrypt(PGPCorpus.crlf(PGPCorpus.fakeMessage + "\n"))])

        engine.decryption = .failure(.noSecretKey)
        let failed = await security(PGPCorpus.encrypted, engine)
        XCTAssertEqual(failed?.encryption, .failed(.noSecretKey))

        engine.decryption = .failure(.notIntegrityProtected)
        let result4 = await security(PGPCorpus.encrypted, engine)
        XCTAssertEqual(try reason(result4), .notIntegrityProtected)
    }

    /// EFAIL direct exfiltration: the engine is not even called for an
    /// encrypted part of a larger message until the user asks.
    func testPartlyEncryptedIsDecryptedOnlyOnRequest() async throws {
        let engine = FakeOpenPGPEngine()
        engine.decryption = .success(PGPDecryptionResult(plaintext: Data("hi".utf8), signatures: []))
        let automatic = await security(PGPCorpus.partlyEncrypted, engine)
        XCTAssertEqual(automatic?.encryption, .notDecrypted)
        XCTAssertEqual(engine.calls, [])
        XCTAssertEqual(PGPSecurityRules.indicator(for: try XCTUnwrap(automatic)).render.decryptedContent,
                       .onRequest)

        let asked = await security(PGPCorpus.partlyEncrypted, engine, decryptPartOnRequest: true)
        let indicator = PGPSecurityRules.indicator(for: try XCTUnwrap(asked))
        XCTAssertEqual(indicator.render, PGPRenderPolicy(decryptedContent: .separateView,
                                                         blocksRemoteContent: true))
        XCTAssertEqual(engine.calls.count, 1)
    }

    // MARK: - Keys

    func testKeysCanBeListedAndDeleted() async throws {
        let engine = FakeOpenPGPEngine()
        engine.importable = [FakeOpenPGPEngine.alice, FakeOpenPGPEngine.mallory]
        _ = try await engine.importKeys(Data("k".utf8))
        let listed = try await engine.keys()
        XCTAssertEqual(listed.count, 2)
        try await engine.deleteKey(FakeOpenPGPEngine.alice.key)
        let remaining = try await engine.keys()
        XCTAssertEqual(remaining, [FakeOpenPGPEngine.mallory])
    }

    // MARK: - The switch

    /// Off: nothing is parsed, found or sent to an engine, for any message.
    func testSwitchedOffDoesNothing() async {
        let engine = aliceSigned()
        for message in [PGPCorpus.signedSimple(), PGPCorpus.encrypted, PGPCorpus.inlineSigned,
                        PGPCorpus.keyAttachment, PGPCorpus.malformedSigned, PGPCorpus.partlyEncrypted] {
            let raw = PGPCorpus.crlf(message)
            XCTAssertEqual(PGPInspection.findings(inRaw: raw, enabled: false), [])
            let result = await PGPInspection.security(ofRaw: raw, engine: engine, enabled: false,
                                                      decryptPartOnRequest: true)
            XCTAssertNil(result)
            XCTAssertEqual(PGPStructure.findings(in: MIMEOutline(raw: RawMIME.parse(raw), in: raw),
                                                 enabled: false), [])
        }
        XCTAssertEqual(engine.calls, [])
    }

    func testOnlyAnExplicitYesTurnsItOn() {
        XCTAssertFalse(PGPFeatures.configured(in: nil))
        XCTAssertFalse(PGPFeatures.configured(in: [:]))
        XCTAssertFalse(PGPFeatures.configured(in: [PGPFeatures.infoKey: "$(MISHMAIL_PGP)"]))
        XCTAssertFalse(PGPFeatures.configured(in: [PGPFeatures.infoKey: ""]))
        XCTAssertFalse(PGPFeatures.configured(in: [PGPFeatures.infoKey: true]))
        XCTAssertFalse(PGPFeatures.configured(in: [AIFeatures.infoKey: "YES"]), "not the AI switch")
        XCTAssertTrue(PGPFeatures.configured(in: [PGPFeatures.infoKey: "YES"]))
    }

    /// Info.plist only forwards the build setting, the tracked xcconfig sets
    /// it to empty before Local.xcconfig, project.yml cannot override it,
    /// and builds that leave the Mac take the tracked value and check it.
    func testTrackedConfigurationShipsWithItOff() throws {
        let plistData = try Data(contentsOf: ForkIdentityTests.repoRoot
            .appendingPathComponent("Sources/MishMail/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: plistData, format: nil) as? [String: Any])
        XCTAssertEqual(plist[PGPFeatures.infoKey] as? String, "$(MISHMAIL_PGP)")

        let xcconfig = try ForkIdentityTests.repoFile("Config/Signing.xcconfig")
        let lines = xcconfig.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(lines.filter { !$0.hasPrefix("//") && $0.hasPrefix("MISHMAIL_PGP") },
                       ["MISHMAIL_PGP ="])
        let assignment = try XCTUnwrap(lines.firstIndex(of: "MISHMAIL_PGP ="))
        let include = try XCTUnwrap(lines.firstIndex(of: "#include? \"Local.xcconfig\""))
        XCTAssertLessThan(assignment, include)
        XCTAssertFalse(try ForkIdentityTests.repoFile("project.yml").contains("MISHMAIL_PGP"))

        let makefile = try ForkIdentityTests.repoFile("Makefile")
        XCTAssertTrue(makefile.contains("SHIP_PGP_FLAGS = MISHMAIL_PGP=$(TRACKED_PGP)\n"))
        XCTAssertEqual(makefile.components(separatedBy: "$(SHIP_AI_FLAGS) $(SHIP_PGP_FLAGS)").count - 1,
                       makefile.components(separatedBy: "$(SHIP_AI_FLAGS)").count - 1,
                       "every shipping build passes both switches")
        for app in ["RELEASE_APP", "SHIP_APP"] {
            XCTAssertTrue(makefile.contains(
                "\t$(call check_ai_switch,$(\(app)))\n\t$(call check_pgp_switch,$(\(app)))\n"), app)
        }
    }

    /// Outside `PGP/`, OpenPGP code is reached from these files only. Any
    /// identifier with the `PGP`, `OpenPGP` or `RPGP` prefix, or one of the
    /// MIME types defined in `PGP/`, counts. The schema (v62) and the
    /// account purge touch a table that stays empty with the switch off;
    /// every other entry point is `PGPCenter`, whose methods return first
    /// with the switch off (`PGPCenterTests`), or checks `PGPFeatures`
    /// itself. A new file that reaches into `PGP/` must be added here, and
    /// gated, on purpose.
    func testAppCodeReachesItOnlyThroughTheSwitch() throws {
        let pattern = try NSRegularExpression(
            pattern: #"\b(?:PGP[A-Z]\w*|OpenPGP\w*|RPGP\w*|RawMIME\w*|MIMEContentType|MIMEOutline)\b"#)
        let sources = ForkIdentityTests.repoRoot.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var users: [String: String] = [:]
        for case let url as URL in files where url.pathExtension == "swift"
            && !url.path.contains("/Sources/MishMail/PGP/") {
            let text = try String(contentsOf: url, encoding: .utf8)
            if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                users[url.lastPathComponent] = text
            }
        }
        XCTAssertEqual(Set(users.keys), [
            "Database.swift", "AccountLifecycle.swift", "GmailClient.swift",
            "MailStore.swift", "MailStore+Accounts.swift",
            "ThreadDetailView.swift", "SettingsView.swift",
            "PGPMessageViews.swift", "PGPKeySettings.swift",
        ])
        // Gated where they start: the message card's candidate check and the
        // Settings pane read the switch; the views draw only what
        // `PGPCenter` produced.
        XCTAssertTrue(users["ThreadDetailView.swift"]?.contains("enabled: PGPFeatures.isEnabled") ?? false)
        XCTAssertEqual(users["SettingsView.swift"]?.components(separatedBy: "PGPFeatures.isEnabled").count, 3)
        XCTAssertTrue(users["MailStore.swift"]?.contains("PGPCenter(database: AppDatabase.shared.dbPool)") ?? false,
                      "the app's center takes the build's switch")
    }

    /// The corpus and the sources carry no private-key block.
    func testNoPrivateKeyMaterialInTheRepositorySources() throws {
        let marker = "-----BEGIN PGP " + "PRIVATE KEY BLOCK-----"
        var hits: [String] = []
        for dir in ["Sources", "Tests"] {
            let root = ForkIdentityTests.repoRoot.appendingPathComponent(dir)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in files where url.pathExtension == "swift" {
                if try String(contentsOf: url, encoding: .utf8).contains(marker) {
                    hits.append(url.lastPathComponent)
                }
            }
        }
        XCTAssertEqual(hits, [])
    }
}
