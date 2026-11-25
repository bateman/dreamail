import XCTest

/// Recognising OpenPGP messages by structure alone (step 4B): MIME types,
/// parameters, file names and armor header lines.
final class PGPStructureTests: XCTestCase {

    private func findings(_ message: String) -> [PGPLocatedFinding] {
        PGPInspection.findings(inRaw: PGPCorpus.crlf(message), enabled: true)
    }

    private func textFindings(_ text: String) -> [PGPLocatedFinding] {
        PGPStructure.findings(in: MIMEOutline(contentType: .defaultText, text: text), enabled: true)
    }

    func testPGPMIMEAtTheRootCoversTheWholeMessage() {
        let signed = findings(PGPCorpus.signedSimple())
        XCTAssertEqual(signed, [PGPLocatedFinding(.mimeSigned, path: [])])
        XCTAssertTrue(signed[0].coversWholeMessage)

        let encrypted = findings(PGPCorpus.encrypted)
        XCTAssertEqual(encrypted, [PGPLocatedFinding(.mimeEncrypted, path: [])])
        XCTAssertTrue(encrypted[0].coversWholeMessage)
    }

    func testASignedOrEncryptedPartInsideAWrapperCoversOnlyPartOfTheMessage() {
        let signed = findings(PGPCorpus.listWrapped)
        XCTAssertEqual(signed, [PGPLocatedFinding(.mimeSigned, path: [0])])
        XCTAssertFalse(signed[0].coversWholeMessage)

        let encrypted = findings(PGPCorpus.partlyEncrypted)
        XCTAssertEqual(encrypted, [PGPLocatedFinding(.mimeEncrypted, path: [1])])
        XCTAssertFalse(encrypted[0].coversWholeMessage)
    }

    func testAttachmentsInsideASignedPartAreStillReported() {
        XCTAssertEqual(findings(PGPCorpus.signedNested), [PGPLocatedFinding(.mimeSigned, path: [])])
        XCTAssertEqual(findings(PGPCorpus.keyAttachment), [
            PGPLocatedFinding(.attachment(.publicKey), path: [1]),
            PGPLocatedFinding(.attachment(.signature), path: [2]),
            PGPLocatedFinding(.attachment(.encrypted), path: [3]),
        ])
    }

    func testMalformedAndForeignStructures() {
        XCTAssertEqual(findings(PGPCorpus.malformedSigned), [PGPLocatedFinding(.malformedMIME, path: [])])
        XCTAssertEqual(findings(PGPCorpus.smimeSigned), [])
        XCTAssertEqual(findings(PGPCorpus.plain), [])
        XCTAssertEqual(findings(PGPCorpus.plainLookingSigned), [], "words and headers are not a signature")
    }

    /// Structures other parsers may read differently are malformed: a second
    /// Content-Type, a repeated boundary, an RFC 2231 boundary.
    func testAmbiguousSignedStructuresAreMalformed() {
        for variant in ["two-content-types", "two-boundaries", "rfc2231-boundary"] {
            XCTAssertEqual(findings(PGPCorpus.signedAmbiguous(variant)),
                           [PGPLocatedFinding(.malformedMIME, path: [])], variant)
        }
    }

    /// A signed part the parser could not read to the end is malformed.
    func testTruncatedSignedStructureIsMalformed() {
        XCTAssertEqual(findings(PGPCorpus.signedTooDeep(depth: 3)),
                       [PGPLocatedFinding(.mimeSigned, path: [])])
        XCTAssertEqual(findings(PGPCorpus.signedTooDeep(depth: RawMIME.maxDepth + 2)),
                       [PGPLocatedFinding(.malformedMIME, path: [])])
    }

    func testInlineArmor() {
        let signed = findings(PGPCorpus.inlineSigned)
        XCTAssertEqual(signed, [PGPLocatedFinding(.inlineSigned, path: [])])
        XCTAssertTrue(signed[0].coversWholeMessage)

        let prefaced = findings(PGPCorpus.inlineEncryptedWithPreface)
        XCTAssertEqual(prefaced, [PGPLocatedFinding(.inlineEncrypted, path: [],
                                                    hasTextOutsideArmor: true)])
        XCTAssertFalse(prefaced[0].coversWholeMessage)

        XCTAssertEqual(findings(PGPCorpus.quotedArmorReply), [], "quoted armor is not the message's")
        XCTAssertEqual(findings(PGPCorpus.truncatedArmor), [], "a begin line alone is not a block")
    }

    /// Each of two blocks covers only part of the message.
    func testTwoBlocksNeitherCoversTheWholeMessage() {
        let two = findings(PGPCorpus.twoInlineBlocks)
        XCTAssertEqual(two.count, 2)
        XCTAssertTrue(two.allSatisfy { $0.finding == .inlineEncrypted && !$0.coversWholeMessage })
    }

    func testArmorBlocksInCRLFAndLFText() {
        for text in [PGPCorpus.fakeMessage, PGPCorpus.fakeMessage.replacingOccurrences(of: "\n", with: "\r\n"),
                     PGPCorpus.fakeMessage.replacingOccurrences(of: "-----\n", with: "-----  \t\n")] {
            XCTAssertEqual(textFindings(text), [PGPLocatedFinding(.inlineEncrypted, path: [])], text)
        }
        XCTAssertEqual(textFindings(PGPCorpus.fakePublicKey), [PGPLocatedFinding(.inlinePublicKey, path: [])])
        XCTAssertEqual(textFindings(" " + PGPCorpus.fakeMessage), [], "indented is not armor")
        // An unterminated block does not hide a complete one after it.
        XCTAssertEqual(textFindings("-----BEGIN PGP MESSAGE-----\n" + PGPCorpus.fakePublicKey),
                       [PGPLocatedFinding(.inlinePublicKey, path: [], hasTextOutsideArmor: true)])
    }

    /// One pass over the text however many unterminated begin lines it has
    /// (the old scan searched to the end once per begin line).
    func testUnterminatedBeginLinesCostOnePass() {
        let begins = String(repeating: "-----BEGIN PGP MESSAGE-----\n", count: 200_000)
        let start = Date()
        XCTAssertEqual(textFindings(begins + "-----END PGP SIGNATURE-----\n"), [])
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "quadratic scan")
    }

    // MARK: - Gmail format=full

    /// From Gmail's decoded tree the structure is visible (to know which
    /// messages need their raw form), though the signed bytes are not.
    func testGmailPayloadOutline() throws {
        let json = """
            {"mimeType": "multipart/signed",
             "headers": [{"name": "Content-Type",
                          "value": "multipart/signed; micalg=pgp-sha256; protocol=\\"application/pgp-signature\\"; boundary=\\"b\\""}],
             "parts": [
               {"mimeType": "text/plain", "headers": [{"name": "Content-Type", "value": "text/plain"}],
                "body": {"data": "SGVsbG8"}},
               {"mimeType": "application/pgp-signature", "filename": "signature.asc",
                "headers": [{"name": "Content-Type", "value": "application/pgp-signature"}],
                "body": {"attachmentId": "att-1", "size": 100}}
             ]}
            """
        let part = try JSONDecoder().decode(GMessage.Part.self, from: Data(json.utf8))
        XCTAssertEqual(PGPInspection.findings(inGmail: part, enabled: true),
                       [PGPLocatedFinding(.mimeSigned, path: [])])

        let inline = try JSONDecoder().decode(GMessage.Part.self, from: Data("""
            {"mimeType": "text/plain", "body": {"data": "\(base64URL(PGPCorpus.inlineSignedBody))"}}
            """.utf8))
        XCTAssertEqual(PGPInspection.findings(inGmail: inline, enabled: true),
                       [PGPLocatedFinding(.inlineSigned, path: [])])
        XCTAssertEqual(PGPInspection.findings(inGmail: inline, enabled: false), [])
        XCTAssertEqual(PGPInspection.findings(inGmail: nil, enabled: true), [])

        let twoTypes = try JSONDecoder().decode(GMessage.Part.self, from: Data(json.replacingOccurrences(
            of: #""headers": [{"name": "Content-Type","#,
            with: #""headers": [{"name": "Content-Type", "value": "text/plain"}, {"name": "Content-Type","#)
            .utf8))
        XCTAssertNotEqual(PGPInspection.findings(inGmail: twoTypes, enabled: true),
                          [PGPLocatedFinding(.mimeSigned, path: [])], "duplicate Content-Type")
    }

    private func base64URL(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
