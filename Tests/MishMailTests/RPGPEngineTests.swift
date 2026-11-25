import XCTest

/// `RPGPEngine` against canned library answers: the JSON contract of
/// the dreamail-openpgp library and how it maps onto the engine types (step 4B).
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
        func importPublic(_ data: Data, _ now: Int64) -> RPGPRawReply {
            answer("importPublic", now)
        }
        func importSecret(_ data: Data, _ now: Int64) -> RPGPRawReply {
            answer("importSecret", now)
        }
    }

    private final class MemoryStore: PGPKeyStore, @unchecked Sendable {
        var certs = Data("certs".utf8)
        var secrets = Data("sk".utf8)
        private(set) var addedCertificates: [Data] = []
        private(set) var addedSecretKeys: [Data] = []
        private(set) var removed: [PGPKeyReference] = []
        func certificates() async throws -> Data { certs }
        func secretKeys() async throws -> Data { secrets }
        func passphrase() async throws -> Data { Data("pw".utf8) }
        func addCertificates(_ armored: Data) async throws { addedCertificates.append(armored) }
        func addSecretKeys(_ armored: Data) async throws { addedSecretKeys.append(armored) }
        func remove(_ key: PGPKeyReference) async throws { removed.append(key) }
    }

    private let aliceJSON = """
        {"fingerprint":"AAAA0000","user_ids":["Alice <alice@example.org>"],"has_secret":false,
         "created":1700000000,"expires":null,"validity":"valid"}
        """

    private func engine(_ json: String, data: Data = Data(), secrets: Data = Data("sk".utf8),
                        store: MemoryStore = MemoryStore()) -> (RPGPEngine, Canned) {
        let canned = Canned()
        canned.reply = RPGPRawReply(json: Data(json.utf8), data: data)
        store.secrets = secrets
        return (RPGPEngine(bindings: canned, store: store,
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
                                  validity: .valid)
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
                              ("not_integrity_protected", .notIntegrityProtected),
                              ("too_large", .tooLarge),
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

    func testDecryptReturnsPlaintextAndInnerSignatures() async throws {
        let (engine, canned) = engine(#"""
            {"ok":true,"integrity_protected":true,"signatures":[{"status":"bad"}]}
            """#, data: Data("plain".utf8))
        let result = try await engine.decrypt(Data("m".utf8))
        XCTAssertEqual(result, PGPDecryptionResult(plaintext: Data("plain".utf8), signatures: [.bad]))
        XCTAssertEqual(canned.lastPassphrase, Data("pw".utf8))
    }

    /// Engine contract: no plaintext without a verified integrity check.
    /// An answer that does not say so explicitly is discarded.
    func testPlaintextWithoutIntegrityProtectionNeverLeaves() async {
        for json in [#"{"ok":true,"signatures":[]}"#,
                     #"{"ok":true,"integrity_protected":false,"signatures":[]}"#] {
            let (engine, _) = engine(json, data: Data("tampered plaintext".utf8))
            await assertThrows(.notIntegrityProtected) { _ = try await engine.decrypt(Data("m".utf8)) }
        }
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
              "created":0,"expires":1900000000,"validity":"revoked"},
              {"fingerprint":"cccc","user_ids":[],"has_secret":false,"created":0,"expires":null,
               "validity":"something_new"}]}
            """#, data: Data("reserialized".utf8))
        let imported = try await keys.importKeys(Data("k".utf8))
        XCTAssertEqual(imported.map(\.key.fingerprint), ["BBBB1111", "CCCC"])
        XCTAssertEqual(imported.first?.hasSecretKey, true)
        XCTAssertEqual(imported.map(\.validity), [.revoked, .unsupported], "an unknown state is not trusted")
        XCTAssertEqual(imported.first?.expires, Date(timeIntervalSince1970: 1_900_000_000))
    }

    func testImportListAndDelete() async throws {
        let store = MemoryStore()
        let (engine, canned) = engine(#"""
            {"ok":true,"keys":[\#(aliceJSON)]}
            """#, data: Data("reserialized".utf8), store: store)
        let imported = try await engine.importKeys(Data("what the user pasted".utf8))
        XCTAssertEqual(imported.map(\.key.fingerprint), ["AAAA0000"])
        XCTAssertEqual(store.addedCertificates, [Data("reserialized".utf8)],
                       "only what the library checked and re-serialized is stored")
        XCTAssertEqual(store.addedSecretKeys, [], "public import never stores secret keys")

        // The same key in both stores is listed once, with its secret half.
        let listed = try await engine.keys()
        XCTAssertEqual(listed.map(\.key.fingerprint), ["AAAA0000"])
        XCTAssertEqual(listed.first?.hasSecretKey, true)
        XCTAssertEqual(canned.calls, ["importPublic", "inspectKeys", "inspectKeys"])
        try await engine.deleteKey(PGPKeyReference(fingerprint: "aaaa 0000"))
        XCTAssertEqual(store.removed, [PGPKeyReference(fingerprint: "AAAA0000")])

        store.certs = Data()
        store.secrets = Data()
        let none = try await engine.keys()
        XCTAssertEqual(none, [])
        XCTAssertEqual(canned.calls.count, 3, "an empty store is not sent to the library")
    }

    func testAKeyThatDoesNotParseIsNotStored() async {
        let store = MemoryStore()
        let (engine, _) = engine(#"{"ok":false,"error":"malformed"}"#, store: store)
        await assertThrows(.malformed) { _ = try await engine.importKeys(Data("junk".utf8)) }
        XCTAssertEqual(store.addedCertificates, [])
    }

    func testSecretImportIsSeparateAndStoresBothHalves() async throws {
        let store = MemoryStore()
        let (engine, canned) = engine(#"""
            {"ok":true,"keys":[\#(aliceJSON)]}
            """#, data: Data("reserialized".utf8), store: store)
        _ = try await engine.importSecretKeys(Data("secret".utf8))
        XCTAssertEqual(canned.calls, ["importSecret", "importPublic"])
        XCTAssertEqual(store.addedSecretKeys, [Data("reserialized".utf8)])
        XCTAssertEqual(store.addedCertificates, [Data("reserialized".utf8)])

        let (none, _) = self.engine(#"{"ok":false,"error":"no_secret_key"}"#, store: store)
        await assertThrows(.noSecretKey) { _ = try await none.importSecretKeys(Data("public only".utf8)) }
    }

    /// The whole pipeline: a raw message, the engine over canned bindings,
    /// and the display rules.
    func testPipelineWithTheRPGPEngine() async throws {
        let (engine, _) = engine(#"{"ok":true,"signatures":[{"status":"good","signer":\#(aliceJSON)}]}"#)
        let security = await PGPInspection.security(
            ofRaw: PGPCorpus.crlf(PGPCorpus.signedSimple()), engine: engine, enabled: true)
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
