#if canImport(MishMailRPGP)
import XCTest
import GRDB

/// The linked dreamail-openpgp library end to end, through `RPGPEngine`,
/// the database key store and `PGPInspection`: the bindings free what the
/// library returns, the JSON contract holds, and real signatures, cleartext
/// signatures and encrypted messages come out right.
///
/// The keys, signatures and messages are made at run time by GnuPG in a
/// throwaway home directory: no key material is in the repository. GnuPG is
/// part of the macOS runner image; a Mac without it fails here, saying so.
final class RPGPLinkedTests: XCTestCase {

    // MARK: - GnuPG, for making test data only

    private final class GnuPG {
        let gpg: String
        let home: URL

        init() throws {
            let candidates = ["/opt/homebrew/bin/gpg", "/usr/local/bin/gpg", "/usr/bin/gpg"]
            guard let gpg = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw NSError(domain: "RPGPLinkedTests", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "GnuPG (gpg) is needed to make test keys; none at \(candidates)"])
            }
            self.gpg = gpg
            // Short: gpg-agent's socket path must fit in sockaddr_un.
            home = URL(fileURLWithPath: "/tmp/mmpgp-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }

        func close() {
            let gpgconf = URL(fileURLWithPath: gpg).deletingLastPathComponent().appendingPathComponent("gpgconf")
            _ = try? run(["--homedir", home.path, "--kill", "all"], tool: gpgconf.path)
            try? FileManager.default.removeItem(at: home)
        }

        @discardableResult
        func run(_ args: [String], tool: String? = nil, input: Data? = nil) throws -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool ?? gpg)
            process.arguments = tool == nil ? ["--homedir", home.path, "--batch", "--no-tty", "--quiet"] + args : args
            let out = Pipe(), err = Pipe(), inPipe = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = inPipe
            try process.run()
            if let input { inPipe.fileHandleForWriting.write(input) }
            try inPipe.fileHandleForWriting.close()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            _ = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "RPGPLinkedTests", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "gpg \(args.first ?? "") failed"])
            }
            return data
        }

        private func unlock(_ passphrase: String) -> [String] {
            ["--pinentry-mode", "loopback", "--passphrase", passphrase]
        }

        /// A new key (Ed25519 signing primary, Curve25519 encryption subkey);
        /// returns its fingerprint. GnuPG 2.4 marks its keys as taking its
        /// own OCB packet (type 20, not in RFC 9580) and then encrypts to
        /// them with it; unless `gnupgAEAD`, the preferences are reset so it
        /// writes standard SEIPD v1, as other clients do.
        func makeKey(_ userID: String, passphrase: String = "", gnupgAEAD: Bool = false) throws -> String {
            try run(unlock(passphrase) + ["--quick-gen-key", userID, "ed25519", "sign,cert", "never"])
            let listing = String(decoding: try run(["--with-colons", "--list-keys", userID]), as: UTF8.self)
            let fingerprint = try XCTUnwrap(listing.split(separator: "\n")
                .first { $0.hasPrefix("fpr:") }?.split(separator: ":", omittingEmptySubsequences: false)[9])
            try run(unlock(passphrase) + ["--quick-add-key", String(fingerprint), "cv25519", "encr", "never"])
            if !gnupgAEAD {
                try run(unlock(passphrase) + ["--command-fd", "0", "--edit-key", String(fingerprint)],
                        input: Data("setpref AES256 AES128 SHA256 ZLIB\ny\nsave\n".utf8))
            }
            return String(fingerprint)
        }

        func publicKey(_ fpr: String) throws -> Data { try run(["--armor", "--export", fpr]) }
        func secretKey(_ fpr: String, passphrase: String = "") throws -> Data {
            try run(unlock(passphrase) + ["--armor", "--export-secret-keys", fpr])
        }
        func detachedSignature(_ data: Data, by fpr: String) throws -> Data {
            try run(unlock("") + ["--armor", "--local-user", fpr, "--detach-sign"], input: data)
        }
        func clearsign(_ text: String, by fpr: String) throws -> Data {
            try run(unlock("") + ["--local-user", fpr, "--clearsign"], input: Data(text.utf8))
        }
        func encrypt(_ data: Data, to fpr: String, signedBy signer: String?) throws -> Data {
            try run(unlock("") + ["--armor", "--trust-model", "always", "--recipient", fpr, "--encrypt"]
                        + (signer.map { ["--sign", "--local-user", $0] } ?? []), input: data)
        }
        func dearmor(_ data: Data) throws -> Data { try run(["--dearmor"], input: data) }
        func listPackets(_ data: Data) throws -> String {
            String(decoding: try run(unlock("") + ["--list-packets"], input: data), as: UTF8.self)
        }
    }

    private var gnupg: GnuPG!

    override func setUpWithError() throws {
        gnupg = try GnuPG()
    }

    override func tearDown() {
        gnupg?.close()
        gnupg = nil
    }

    private let account = "a@x.com"

    private func makeEngine() throws -> (RPGPEngine, MemorySecretKeys, PGPPassphrases, DatabaseQueue) {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.account, displayName: self.account, historyId: nil, lastSyncAt: nil,
                        senderName: "").insert(db)
        }
        let secrets = MemorySecretKeys(), passphrases = PGPPassphrases()
        let store = DatabasePGPKeyStore(accountId: account, database: q, secrets: secrets,
                                        passphrases: passphrases)
        return (RPGPEngine(bindings: LinkedRPGPBindings(), store: store), secrets, passphrases, q)
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

    // MARK: - Tests

    func testSignaturesVerifyThroughTheLinkedLibrary() async throws {
        let alice = try gnupg.makeKey("Alice Example <alice@example.org>")
        let (engine, _, _, q) = try makeEngine()
        let signedPart = Data("Content-Type: text/plain; charset=utf-8\r\n\r\nHello Bob\r\n".utf8)
        let signature = try gnupg.detachedSignature(signedPart, by: alice)

        // No key yet: "cannot verify", never valid and never an error.
        let before = try await engine.verifyDetached(signedData: signedPart, signature: signature)
        guard case .unknownKey = before.first, before.count == 1 else { return XCTFail("\(before)") }

        let imported = try await engine.importKeys(try gnupg.publicKey(alice))
        XCTAssertEqual(imported.map(\.key.fingerprint), [alice])
        XCTAssertEqual(imported.first?.userIDs, ["Alice Example <alice@example.org>"])
        XCTAssertEqual(imported.first?.hasSecretKey, false)

        let good = try await engine.verifyDetached(signedData: signedPart, signature: signature)
        guard case .good(let signer) = good.first else { return XCTFail("\(good)") }
        XCTAssertEqual(signer.key.fingerprint, alice)
        let tampered = Data("Content-Type: text/plain; charset=utf-8\r\n\r\nHello Bab\r\n".utf8)
        let bad = try await engine.verifyDetached(signedData: tampered, signature: signature)
        XCTAssertEqual(bad, [.bad])

        // The whole path from a raw PGP/MIME message.
        let raw = Data(("""
            From: Alice Example <alice@example.org>\r
            To: Bob <bob@example.org>\r
            Subject: Signed\r
            MIME-Version: 1.0\r
            Content-Type: multipart/signed; micalg=pgp-sha256; protocol="application/pgp-signature"; boundary="sig"\r
            \r
            --sig\r

            """ + String(decoding: signedPart, as: UTF8.self) + """
            \r
            --sig\r
            Content-Type: application/pgp-signature; name="signature.asc"\r
            \r

            """ + String(decoding: signature, as: UTF8.self) + "\r\n--sig--\r\n").utf8)
        let checked = await PGPInspection.security(ofRaw: raw, engine: engine, enabled: true)
        let security = try XCTUnwrap(checked)
        let indicator = PGPSecurityRules.indicator(for: security)
        XCTAssertEqual(indicator.reason, .signed(address: "alice@example.org"))
        XCTAssertEqual(PGPDisplay.body(for: security, indicator: indicator), .text("Hello Bob\r\n"))

        // The certificate is in the database as the library re-serialized it.
        let rows = try await q.read { try PGPKeyTable.rows($0, accountId: self.account) }
        XCTAssertEqual(rows.map(\.fingerprint), [alice])
        XCTAssertTrue(String(decoding: rows[0].certificate, as: UTF8.self)
            .hasPrefix("-----BEGIN PGP PUBLIC KEY BLOCK-----"))
    }

    func testCleartextSignatureThroughTheLinkedLibrary() async throws {
        let alice = try gnupg.makeKey("Alice Example <alice@example.org>")
        let (engine, _, _, _) = try makeEngine()
        _ = try await engine.importKeys(try gnupg.publicKey(alice))
        let signed = try gnupg.clearsign("Meet at noon.\n- dashes\n", by: alice)
        let result = try await engine.verifyCleartext(signed)
        guard case .good = result.signatures.first else { return XCTFail("\(result.signatures)") }
        XCTAssertTrue(String(decoding: result.signedText, as: UTF8.self).contains("Meet at noon."))

        let forged = Data(String(decoding: signed, as: UTF8.self)
            .replacingOccurrences(of: "noon", with: "dawn").utf8)
        let forgedResult = try await engine.verifyCleartext(forged)
        XCTAssertEqual(forgedResult.signatures, [.bad])
    }

    func testDecryptionWithAnImportedSecretKey() async throws {
        let alice = try gnupg.makeKey("Alice Example <alice@example.org>")
        let bob = try gnupg.makeKey("Bob <bob@example.org>")
        let (engine, secrets, _, q) = try makeEngine()
        _ = try await engine.importKeys(try gnupg.publicKey(alice))
        let message = try gnupg.encrypt(Data("Content-Type: text/plain\r\n\r\nThe plan\r\n".utf8),
                                        to: bob, signedBy: alice)

        await assertThrows(.noSecretKey) { _ = try await engine.decrypt(message) }

        let imported = try await engine.importSecretKeys(try gnupg.secretKey(bob))
        XCTAssertEqual(imported.map(\.key.fingerprint), [bob])
        XCTAssertEqual(Array(secrets.stored.keys), [PGPSecretKeyOwner(accountId: account,
                                                                      key: PGPKeyReference(fingerprint: bob))])
        // Only the flag is in the database; the certificate row holds a
        // public block.
        let row = try await q.read { try PGPKeyTable.rows($0, accountId: self.account) }
            .first { $0.fingerprint == bob }
        XCTAssertEqual(row?.hasSecretKey, true)
        XCTAssertTrue(String(decoding: row?.certificate ?? Data(), as: UTF8.self)
            .hasPrefix("-----BEGIN PGP PUBLIC KEY BLOCK-----"))

        let decrypted = try await engine.decrypt(message)
        XCTAssertEqual(decrypted.plaintext, Data("Content-Type: text/plain\r\n\r\nThe plan\r\n".utf8))
        guard case .good(let signer) = decrypted.signatures.first else {
            return XCTFail("\(decrypted.signatures)")
        }
        XCTAssertEqual(signer.key.fingerprint, alice)

        let listed = try await engine.keys()
        XCTAssertEqual(Set(listed.map(\.key.fingerprint)), [alice, bob])
        XCTAssertEqual(listed.first { $0.key.fingerprint == bob }?.hasSecretKey, true)

        // Deleted means gone: both halves.
        try await engine.deleteKey(PGPKeyReference(fingerprint: bob))
        XCTAssertEqual(secrets.stored, [:])
        let left = try await engine.keys()
        XCTAssertEqual(left.map(\.key.fingerprint), [alice])
        await assertThrows(.noSecretKey) { _ = try await engine.decrypt(message) }
    }

    func testALockedKeyNeedsItsPassphrase() async throws {
        let bob = try gnupg.makeKey("Bob <bob@example.org>", passphrase: "correct horse")
        let (engine, _, passphrases, _) = try makeEngine()
        _ = try await engine.importSecretKeys(try gnupg.secretKey(bob, passphrase: "correct horse"))
        let message = try gnupg.encrypt(Data("secret".utf8), to: bob, signedBy: nil)

        await assertThrows(.passphraseRequired) { _ = try await engine.decrypt(message) }
        passphrases.set(Data("wrong".utf8), accountId: account)
        await assertThrows(.passphraseRequired) { _ = try await engine.decrypt(message) }
        passphrases.set(Data("correct horse".utf8), accountId: account)
        let decrypted = try await engine.decrypt(message)
        XCTAssertEqual(decrypted.plaintext, Data("secret".utf8))
    }

    /// GnuPG wrote its own OCB packet (type 20), not SEIPD.
    private func assertGnuPGOCB(_ message: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let packets = try gnupg.listPackets(message)
        XCTAssertTrue(packets.contains(":aead encrypted packet:"), packets, file: file, line: line)
    }

    /// GnuPG's own OCB packet (type 20, not in RFC 9580), which GnuPG 2.4
    /// sends by default to keys it generated, decrypts since library v0.1.1.
    /// Edited or truncated, it is an error, never plaintext, and reads like
    /// any other failed decryption.
    func testAGnuPGOCBMessage() async throws {
        let bob = try gnupg.makeKey("Bob <bob@example.org>", gnupgAEAD: true)
        let (engine, _, _, _) = try makeEngine()
        _ = try await engine.importSecretKeys(try gnupg.secretKey(bob))
        let message = try gnupg.encrypt(Data("secret".utf8), to: bob, signedBy: nil)
        try assertGnuPGOCB(message)
        let decrypted = try await engine.decrypt(message)
        XCTAssertEqual(decrypted.plaintext, Data("secret".utf8))

        // The packet ends with the last chunk's tag, then the final tag
        // (16 bytes each); the last ciphertext byte is just before them.
        let binary = try gnupg.dearmor(message)
        var ciphertext = binary
        ciphertext[ciphertext.count - 33] ^= 0x01
        var finalTag = binary
        finalTag[finalTag.count - 1] ^= 0x01
        let edited: [(String, Data, PGPEngineError?)] = [
            ("ciphertext", ciphertext, .notIntegrityProtected),
            ("final tag", finalTag, .notIntegrityProtected),
            ("truncated", Data(binary.dropLast(16)), nil),
        ]
        for (name, bytes, expected) in edited {
            do {
                let out = try await engine.decrypt(bytes)
                XCTFail("\(name): decrypted \(out.plaintext.count) bytes of an edited message")
            } catch {
                let failure = try XCTUnwrap(error as? PGPEngineError, "\(name): \(error)")
                if let expected { XCTAssertEqual(failure, expected, name) }
                let security = PGPMessageSecurity(encryption: .failed(failure), signature: .unsigned,
                                                  fromHeader: "Alice <alice@example.org>")
                let body = PGPDisplay.body(for: security, indicator: PGPSecurityRules.indicator(for: security))
                guard case .notice(let notice) = body else { return XCTFail("\(name): \(body)") }
                XCTAssertEqual(notice.text, "This message could not be decrypted.", name)
            }
        }
    }

    /// The round trip above with both keys at GnuPG 2.4's default
    /// preferences, so GnuPG writes its OCB packet, signed inside.
    func testRoundTripWithGnuPGDefaultPreferences() async throws {
        let alice = try gnupg.makeKey("Alice Example <alice@example.org>", gnupgAEAD: true)
        let bob = try gnupg.makeKey("Bob <bob@example.org>", gnupgAEAD: true)
        let (engine, _, _, _) = try makeEngine()
        _ = try await engine.importKeys(try gnupg.publicKey(alice))
        _ = try await engine.importSecretKeys(try gnupg.secretKey(bob))
        let body = Data("Content-Type: text/plain\r\n\r\nThe plan\r\n".utf8)
        let message = try gnupg.encrypt(body, to: bob, signedBy: alice)
        try assertGnuPGOCB(message)

        let decrypted = try await engine.decrypt(message)
        XCTAssertEqual(decrypted.plaintext, body)
        guard decrypted.signatures.count == 1, case .good(let signer) = decrypted.signatures.first else {
            return XCTFail("\(decrypted.signatures)")
        }
        XCTAssertEqual(signer.key.fingerprint, alice)
    }

    func testTheLibraryRefusesJunk() async throws {
        let (engine, _, _, q) = try makeEngine()
        await assertThrows(.malformed) { _ = try await engine.importKeys(Data("not a key".utf8)) }
        await assertThrows(.malformed) { _ = try await engine.importSecretKeys(Data("not a key".utf8)) }
        let none = try await q.read { try PGPKeyRecord.fetchCount($0) }
        XCTAssertEqual(none, 0)
        let bindings = LinkedRPGPBindings()
        let reply = bindings.inspectKeys(Data(), 1_800_000_000)
        XCTAssertEqual(try? RPGPReply.decode(reply.json), nil, "an empty input is not a key")
        // A refused clock is an error, never read as 1970.
        XCTAssertThrowsError(try RPGPReply.decode(bindings.importPublic(Data("x".utf8), 0).json))
    }
}
#endif
