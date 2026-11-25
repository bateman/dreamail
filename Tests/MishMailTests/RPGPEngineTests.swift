import XCTest

/// `RPGPEngine` against canned library answers: the JSON contract of
/// `Vendor/rpgp-ffi` and how it maps onto the engine types (step 4B).
/// The library itself is tested by its own Rust tests.
final class RPGPEngineTests: XCTestCase {

    private final class Canned: RPGPBindings, @unchecked Sendable {
        var reply = RPGPRawReply(json: Data(), data: Data())
        private(set) var calls: [String] = []
        private(set) var lastPassphrase: Data?
        private(set) var lastNow: Int64?

        private func answer(_ name: String, _ now: Int64) -> RPGPRawReply {
            calls.append(name)
            lastNow = now
            return reply
        }
        func verifyDetached(_ data: Data, _ signature: Data, _ certs: Data, _ now: Int64) -> RPGPRawReply {
            answer("verifyDetached", now)
        }
        func verifyCleartext(_ message: Data, _ certs: Data, _ now: Int64) -> RPGPRawReply {
            answer("verifyCleartext", now)
        }
        func decrypt(_ message: Data, _ secretKeys: Data, _ passphrase: Data, _ certs: Data,
                     _ now: Int64) -> RPGPRawReply {
            lastPassphrase = passphrase
            return answer("decrypt", now)
        }
        func inspectKeys(_ data: Data, _ now: Int64) -> RPGPRawReply {
            answer("inspectKeys", now)
        }
    }

    private let aliceJSON = """
        {"fingerprint":"AAAA0000","user_ids":["Alice <alice@example.org>"],"has_secret":false,
         "created":1700000000,"expires":null,"revoked":false}
        """

    private func engine(_ json: String, data: Data = Data(), secrets: Data = Data("sk".utf8))
        -> (RPGPEngine, Canned) {
        let canned = Canned()
        canned.reply = RPGPRawReply(json: Data(json.utf8), data: data)
        let keys = PGPKeyMaterial(certificates: { Data("certs".utf8) },
                                  secretKeys: { secrets },
                                  passphrase: { Data("pw".utf8) })
        return (RPGPEngine(bindings: canned, keys: keys,
                           now: { Date(timeIntervalSince1970: 1_800_000_000) }), canned)
    }

    func testSignatureStatusesMap() async throws {
        let (engine, canned) = engine("""
            {"ok":true,"signatures":[
              {"status":"good","signer":\(aliceJSON)},
              {"status":"bad"},
              {"status":"unknown_key","key_id":"1234ABCD"},
              {"status":"key_not_valid","signer":\(aliceJSON)},
              {"status":"unsupported"},
              {"status":"something_new"}]}
            """)
        let results = try await engine.verifyDetached(signedData: Data("x".utf8), signature: Data("s".utf8))
        let alice = PGPKeySummary(key: PGPKeyReference(fingerprint: "AAAA0000"),
                                  userIDs: ["Alice <alice@example.org>"], hasSecretKey: false,
                                  created: Date(timeIntervalSince1970: 1_700_000_000), expires: nil,
                                  isRevoked: false)
        XCTAssertEqual(results, [.good(signer: alice), .bad, .unknownKey(keyID: "1234ABCD"),
                                 .keyNotValid(signer: alice), .unsupported, .unsupported])
        XCTAssertEqual(canned.calls, ["verifyDetached"])
        XCTAssertEqual(canned.lastNow, 1_800_000_000)
    }

    func testAGoodSignatureWithoutASignerIsMalformed() async {
        let (engine, _) = engine(#"{"ok":true,"signatures":[{"status":"good"}]}"#)
        await assertThrows(.malformed) {
            _ = try await engine.verifyDetached(signedData: Data(), signature: Data())
        }
    }

    func testErrorsMap() async {
        for (code, error) in [("no_secret_key", PGPEngineError.noSecretKey),
                              ("passphrase_required", .passphraseRequired),
                              ("unsupported", .unsupported), ("malformed", .malformed),
                              ("internal", .malformed), ("unheard_of", .malformed)] {
            let (engine, _) = engine(#"{"ok":false,"error":"\#(code)"}"#)
            await assertThrows(error) { _ = try await engine.decrypt(Data("m".utf8)) }
        }
        for junk in ["", "not json", "{}", #"{"ok":"yes"}"#] {
            let (engine, _) = engine(junk)
            await assertThrows(.malformed) { _ = try await engine.importKeys(Data()) }
        }
    }

    func testDecryptReturnsPlaintextIntegrityAndInnerSignatures() async throws {
        let (engine, canned) = engine(#"""
            {"ok":true,"integrity_protected":true,"signatures":[{"status":"bad"}]}
            """#, data: Data("plain".utf8))
        let result = try await engine.decrypt(Data("m".utf8))
        XCTAssertEqual(result, PGPDecryptionResult(plaintext: Data("plain".utf8),
                                                   integrityProtected: true, signatures: [.bad]))
        XCTAssertEqual(canned.lastPassphrase, Data("pw".utf8))

        let (unprotected, _) = self.engine(#"{"ok":true,"signatures":[]}"#, data: Data("p".utf8))
        let missing = try await unprotected.decrypt(Data("m".utf8))
        XCTAssertFalse(missing.integrityProtected, "absent means not protected")
    }

    func testDecryptWithoutSecretKeysDoesNotCallTheLibrary() async {
        let (engine, canned) = engine(#"{"ok":true}"#, secrets: Data())
        await assertThrows(.noSecretKey) { _ = try await engine.decrypt(Data("m".utf8)) }
        XCTAssertEqual(canned.calls, [])
    }

    func testCleartextAndKeys() async throws {
        let (engine, _) = engine(#"{"ok":true,"signatures":[{"status":"bad"}]}"#,
                                 data: Data("signed\r\n".utf8))
        let cleartext = try await engine.verifyCleartext(Data("m".utf8))
        XCTAssertEqual(cleartext, PGPCleartextResult(signedText: Data("signed\r\n".utf8),
                                                     signatures: [.bad]))

        let (keys, _) = self.engine(#"""
            {"ok":true,"keys":[{"fingerprint":"bbbb 1111","user_ids":[],"has_secret":true,
              "created":0,"expires":1900000000,"revoked":true}]}
            """#)
        let imported = try await keys.importKeys(Data("k".utf8))
        XCTAssertEqual(imported.map(\.key.fingerprint), ["BBBB1111"])
        XCTAssertEqual(imported.first?.hasSecretKey, true)
        XCTAssertEqual(imported.first?.isRevoked, true)
        XCTAssertEqual(imported.first?.expires, Date(timeIntervalSince1970: 1_900_000_000))
    }

    func testSigningAndEncryptionAreNotOfferedInScopeB() async {
        let (engine, canned) = engine(#"{"ok":true}"#)
        await assertThrows(.unsupported) {
            _ = try await engine.sign(Data(), as: PGPKeyReference(fingerprint: "A"), detached: true)
        }
        await assertThrows(.unsupported) {
            _ = try await engine.encrypt(Data(), to: [], signedBy: nil)
        }
        XCTAssertEqual(canned.calls, [])
    }

    /// The whole pipeline: a raw message, the engine over canned bindings,
    /// and the display rules.
    func testPipelineWithTheRPGPEngine() async throws {
        let (engine, _) = engine(#"{"ok":true,"signatures":[{"status":"good","signer":\#(aliceJSON)}]}"#)
        let security = await PGPInspection.security(
            ofRaw: PGPCorpus.crlf(PGPCorpus.signedSimple()),
            fromHeader: "Alice Example <alice@example.org>", engine: engine, enabled: true)
        XCTAssertEqual(PGPSecurityRules.indicator(for: try XCTUnwrap(security)).reason,
                       .signed(address: "alice@example.org"))
    }

    private func assertThrows(_ expected: PGPEngineError, file: StaticString = #filePath,
                              line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PGPEngineError, expected, file: file, line: line)
        }
    }
}
