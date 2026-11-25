import XCTest

/// Recognising OpenPGP messages by structure alone (step 4B): MIME types,
/// parameters, file names and armor header lines.
final class PGPStructureTests: XCTestCase {

    private func findings(_ message: String) -> [PGPLocatedFinding] {
        PGPInspection.findings(inRaw: PGPCorpus.crlf(message), enabled: true)
    }

    func testPGPMIMEAtTheRootCoversTheWholeMessage() {
        let signed = findings(PGPCorpus.signedSimple())
        XCTAssertEqual(signed, [PGPLocatedFinding(.mimeSigned, path: [])])
        XCTAssertTrue(signed[0].coversWholeMessage)

        let encrypted = findings(PGPCorpus.encrypted)
        XCTAssertEqual(encrypted, [PGPLocatedFinding(.mimeEncrypted, path: [])])
        XCTAssertTrue(encrypted[0].coversWholeMessage)
    }

    func testASignedPartInsideAWrapperCoversOnlyPartOfTheMessage() {
        let found = findings(PGPCorpus.listWrapped)
        XCTAssertEqual(found, [PGPLocatedFinding(.mimeSigned, path: [0])])
        XCTAssertFalse(found[0].coversWholeMessage)
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

    func testArmorBlocksInCRLFAndLFText() {
        for text in [PGPCorpus.fakeMessage, PGPCorpus.fakeMessage.replacingOccurrences(of: "\n", with: "\r\n"),
                     PGPCorpus.fakeMessage.replacingOccurrences(of: "-----\n", with: "-----  \t\n")] {
            let blocks = PGPArmor.blocks(in: text)
            XCTAssertEqual(blocks.map(\.kind), [.message], text)
            XCTAssertEqual(blocks.first?.hasTextOutside, false)
        }
        XCTAssertEqual(PGPArmor.blocks(in: PGPCorpus.fakePublicKey).map(\.kind), [.publicKey])
        XCTAssertEqual(PGPArmor.blocks(in: " " + PGPCorpus.fakeMessage), [], "indented is not armor")
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
    }

    private func base64URL(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
