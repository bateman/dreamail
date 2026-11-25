import XCTest

/// The path from a raw message to the engine and back (step 4B), and the
/// build switch that keeps all of it off.
final class PGPInspectionTests: XCTestCase {
    private let from = "Alice Example <alice@example.org>"

    // MARK: - Pipeline

    func testEngineReceivesExactlyTheCanonicalSignedBytes() async throws {
        let engine = FakeOpenPGPEngine()
        engine.detachedResults[PGPCorpus.signedPartCanonical] = [.good(signer: FakeOpenPGPEngine.alice)]

        for raw in [PGPCorpus.crlf(PGPCorpus.signedSimple()), PGPCorpus.lf(PGPCorpus.signedSimple())] {
            let security = await PGPInspection.security(ofRaw: raw, fromHeader: from,
                                                        engine: engine, enabled: true)
            let indicator = PGPSecurityRules.indicator(for: try XCTUnwrap(security))
            XCTAssertEqual(indicator.reason, .signed(address: "alice@example.org"))
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
        let engine = FakeOpenPGPEngine()
        engine.detachedResults[PGPCorpus.signedPartCanonical] = [.good(signer: FakeOpenPGPEngine.alice)]
        let tampered = PGPCorpus.signedSimple().replacingOccurrences(of: "Hello Bob", with: "Hello Bab")
        let security = await PGPInspection.security(ofRaw: PGPCorpus.crlf(tampered), fromHeader: from,
                                                    engine: engine, enabled: true)
        XCTAssertEqual(PGPSecurityRules.indicator(for: try XCTUnwrap(security)).reason, .badSignature)
    }

    func testListFooterMakesAGoodSignaturePartial() async throws {
        let engine = FakeOpenPGPEngine()
        let signedPart = Data("Content-Type: text/plain; charset=utf-8\r\n\r\nThe signed post.".utf8)
        engine.detachedResults[signedPart] = [.good(signer: FakeOpenPGPEngine.alice)]
        let security = await PGPInspection.security(ofRaw: PGPCorpus.crlf(PGPCorpus.listWrapped),
                                                    fromHeader: from, engine: engine, enabled: true)
        let indicator = PGPSecurityRules.indicator(for: try XCTUnwrap(security))
        XCTAssertEqual(indicator.reason, .partlySigned)
        XCTAssertFalse(indicator.showsSignedMark)
        XCTAssertEqual(engine.calls, [.verifyDetached(signedData: signedPart,
                                                      signature: PGPCorpus.crlf(PGPCorpus.fakeSignature))])
    }

    func testEncryptedMessageGoesToDecrypt() async throws {
        let engine = FakeOpenPGPEngine()
        engine.decryption = .success(PGPDecryptionResult(plaintext: Data("hi".utf8),
                                                         integrityProtected: true, signatures: []))
        let raw = PGPCorpus.crlf(PGPCorpus.encrypted)
        let security = await PGPInspection.security(ofRaw: raw, fromHeader: from,
                                                    engine: engine, enabled: true)
        XCTAssertEqual(PGPSecurityRules.indicator(for: try XCTUnwrap(security)).reason, .encrypted)
        XCTAssertEqual(engine.calls, [.decrypt(PGPCorpus.crlf(PGPCorpus.fakeMessage + "\n"))])

        engine.decryption = .failure(.noSecretKey)
        let failed = await PGPInspection.security(ofRaw: raw, fromHeader: from,
                                                  engine: engine, enabled: true)
        XCTAssertEqual(failed?.encryption, .failed(.noSecretKey))
    }

    func testWithoutALibraryNothingIsClaimed() async throws {
        let security = await PGPInspection.security(
            ofRaw: PGPCorpus.crlf(PGPCorpus.signedSimple()), fromHeader: from,
            engine: UnavailableOpenPGPEngine(), enabled: true)
        XCTAssertEqual(security?.signature, .notChecked(.unavailable))
        XCTAssertFalse(PGPSecurityRules.indicator(for: try XCTUnwrap(security)).showsSignedMark)
    }

    func testMalformedAndPlainMessages() async {
        let engine = FakeOpenPGPEngine()
        let malformed = await PGPInspection.security(ofRaw: PGPCorpus.crlf(PGPCorpus.malformedSigned),
                                                     fromHeader: from, engine: engine, enabled: true)
        XCTAssertEqual(malformed?.signature, .notChecked(.malformed))
        for message in [PGPCorpus.plain, PGPCorpus.smimeSigned, PGPCorpus.plainLookingSigned] {
            let none = await PGPInspection.security(ofRaw: PGPCorpus.crlf(message), fromHeader: from,
                                                    engine: engine, enabled: true)
            XCTAssertNil(none)
        }
        XCTAssertEqual(engine.calls, [])
    }

    // MARK: - The switch

    /// Off: nothing is parsed, found or sent to an engine, for any message.
    func testSwitchedOffDoesNothing() async {
        let engine = FakeOpenPGPEngine()
        engine.detachedResults[PGPCorpus.signedPartCanonical] = [.good(signer: FakeOpenPGPEngine.alice)]
        for message in [PGPCorpus.signedSimple(), PGPCorpus.encrypted, PGPCorpus.inlineSigned,
                        PGPCorpus.keyAttachment, PGPCorpus.malformedSigned] {
            let raw = PGPCorpus.crlf(message)
            XCTAssertEqual(PGPInspection.findings(inRaw: raw, enabled: false), [])
            let security = await PGPInspection.security(ofRaw: raw, fromHeader: from,
                                                        engine: engine, enabled: false)
            XCTAssertNil(security)
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

    /// Nothing outside `PGP/` uses this code yet: with the switch in either
    /// state the app behaves as before. The step that wires it in changes
    /// this list on purpose.
    func testNoAppCodeOutsidePGPUsesIt() throws {
        let sources = ForkIdentityTests.repoRoot.appendingPathComponent("Sources")
        let names = ["PGPFeatures", "PGPInspection", "PGPStructure", "PGPSecurityRules",
                     "OpenPGPEngine", "RawMIME", "PGPArmor", "MIMEOutline"]
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var users: [String] = []
        for case let url as URL in files where url.pathExtension == "swift"
            && !url.path.contains("/Sources/MishMail/PGP/") {
            let text = try String(contentsOf: url, encoding: .utf8)
            users += names.filter { text.contains($0) }.map { "\(url.lastPathComponent): \($0)" }
        }
        XCTAssertEqual(users, [])
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
