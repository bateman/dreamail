import XCTest

/// The structure-only MIME reader under OpenPGP/MIME (step 4B), and above
/// all the exact signed bytes of a `multipart/signed` (RFC 3156 §5), which
/// is the part implementations usually get wrong.
final class PGPRawMIMETests: XCTestCase {

    // MARK: - Signed bytes

    func testSignedBytesAreTheFirstPartExactlyInCRLFForm() throws {
        for raw in [PGPCorpus.crlf(PGPCorpus.signedSimple()), PGPCorpus.lf(PGPCorpus.signedSimple())] {
            let payload = try XCTUnwrap(PGPInspection.payload(at: [], inRaw: raw))
            XCTAssertEqual(payload.signedData, PGPCorpus.signedPartCanonical,
                           String(decoding: payload.signedData, as: UTF8.self))
            XCTAssertEqual(payload.micalg, "pgp-sha256")
            XCTAssertEqual(String(decoding: payload.pgpData, as: UTF8.self)
                .replacingOccurrences(of: "\r\n", with: "\n"), PGPCorpus.fakeSignature)
        }
    }

    /// The CRLF before the next delimiter belongs to the delimiter: the
    /// signed bytes end at "Alice", not "Alice\r\n".
    func testTheLineBreakBeforeTheDelimiterIsNotSigned() throws {
        let payload = try XCTUnwrap(PGPInspection.payload(
            at: [], inRaw: PGPCorpus.crlf(PGPCorpus.signedSimple())))
        XCTAssertTrue(String(decoding: payload.signedData, as: UTF8.self).hasSuffix("\r\nAlice"))
        XCTAssertFalse(payload.signedData.starts(with: Data("\r\n".utf8)))
    }

    func testTransportPaddingAfterADelimiterIsAccepted() throws {
        let raw = PGPCorpus.crlf(PGPCorpus.signedSimple(delimiterSuffix: " \t "))
        let payload = try XCTUnwrap(PGPInspection.payload(at: [], inRaw: raw))
        XCTAssertEqual(payload.signedData, PGPCorpus.signedPartCanonical)
    }

    /// A line that only starts like the boundary is content, and the nested
    /// multipart is signed whole, inner boundaries included.
    func testNestedSignedPartAndBoundaryLookAlikes() throws {
        for raw in [PGPCorpus.crlf(PGPCorpus.signedNested), PGPCorpus.lf(PGPCorpus.signedNested)] {
            let payload = try XCTUnwrap(PGPInspection.payload(at: [], inRaw: raw))
            XCTAssertEqual(payload.signedData, PGPCorpus.signedNestedPartCanonical,
                           String(decoding: payload.signedData, as: UTF8.self))
            XCTAssertEqual(payload.micalg, "pgp-sha512")
        }
        let root = RawMIME.parse(PGPCorpus.crlf(PGPCorpus.signedNested))
        XCTAssertEqual(root.children.count, 2)
        XCTAssertEqual(root.children[0].children.count, 2)
        XCTAssertEqual(root.children[0].children[1].filename, "notes.txt")
    }

    /// Signed bytes are cut from the source unchanged: a part with mixed
    /// line endings keeps its CRLFs, gains CR only before bare LFs, and
    /// keeps a bare CR.
    func testCanonicalFormOnlyAddsCRBeforeBareLF() {
        XCTAssertEqual(RawMIME.canonicalCRLF(Data("a\r\nb\nc\rd\n\n".utf8)),
                       Data("a\r\nb\r\nc\rd\r\n\r\n".utf8))
        XCTAssertEqual(RawMIME.canonicalCRLF(Data()), Data())
        XCTAssertEqual(RawMIME.canonicalCRLF(Data("trailing  \n".utf8)),
                       Data("trailing  \r\n".utf8), "no whitespace stripping")
    }

    func testEncryptedPayloadIsTheOctetStreamBody() throws {
        let payload = try XCTUnwrap(PGPInspection.payload(
            at: [], inRaw: PGPCorpus.lf(PGPCorpus.encrypted)))
        XCTAssertEqual(payload.signedData, Data())
        XCTAssertEqual(String(decoding: payload.pgpData, as: UTF8.self),
                       PGPCorpus.fakeMessage + "\n")
    }

    func testMalformedOrForeignEntitiesGiveNoPayload() {
        XCTAssertNil(PGPInspection.payload(at: [], inRaw: PGPCorpus.lf(PGPCorpus.malformedSigned)))
        XCTAssertNil(PGPInspection.payload(at: [], inRaw: PGPCorpus.lf(PGPCorpus.plain)))
        XCTAssertNil(PGPInspection.payload(at: [5], inRaw: PGPCorpus.lf(PGPCorpus.signedNested)))
    }

    // MARK: - Headers and parameters

    func testHeadersUnfoldAndParametersParse() {
        let root = RawMIME.parse(PGPCorpus.crlf(PGPCorpus.signedSimple()))
        XCTAssertEqual(root.contentType.mimeType, "multipart/signed")
        XCTAssertEqual(root.contentType.parameters["protocol"], "application/pgp-signature")
        XCTAssertEqual(root.contentType.parameters["boundary"], "sig-boundary")
        XCTAssertEqual(root.header("Subject"), "Signed test message")
        XCTAssertEqual(root.children.count, 2)
        XCTAssertEqual(root.children[1].filename, "signature.asc")
    }

    func testContentTypeParsing() {
        let quoted = MIMEContentType(headerValue: #"Multipart/Mixed; BOUNDARY="a;b\"c"; x=1"#)
        XCTAssertEqual(quoted.mimeType, "multipart/mixed")
        XCTAssertEqual(quoted.parameters["boundary"], #"a;b"c"#)
        XCTAssertEqual(quoted.parameters["x"], "1")

        let duplicate = MIMEContentType(headerValue: "multipart/mixed; boundary=first; boundary=second")
        XCTAssertEqual(duplicate.parameters["boundary"], "first", "a later duplicate must not win")

        for bad in [nil, "", "text", "/plain", "text/", "te xt/plain"] {
            XCTAssertEqual(MIMEContentType(headerValue: bad), .defaultText, String(describing: bad))
        }
    }

    func testPartWithoutHeadersAndMessageWithoutBody() {
        let raw = PGPCorpus.lf("""
            Content-Type: multipart/mixed; boundary=x

            --x

            body without headers
            --x--
            """)
        let root = RawMIME.parse(raw)
        XCTAssertEqual(root.children.count, 1)
        XCTAssertEqual(root.children[0].headers, [])
        XCTAssertEqual(root.children[0].contentType, .defaultText)
        XCTAssertEqual(String(decoding: RawMIME.bytes(raw, root.children[0].bodyRange), as: UTF8.self),
                       "body without headers")

        let headersOnly = RawMIME.parse(Data("Subject: only headers".utf8))
        XCTAssertEqual(headersOnly.header("subject"), "only headers")
        XCTAssertTrue(headersOnly.bodyRange.isEmpty)
    }

    func testUnterminatedMultipartKeepsTheLastPart() {
        let raw = PGPCorpus.lf("""
            Content-Type: multipart/mixed; boundary=x

            --x
            Content-Type: text/plain

            never closed
            """)
        let root = RawMIME.parse(raw)
        XCTAssertEqual(root.children.count, 1)
        XCTAssertEqual(String(decoding: RawMIME.decodedBody(root.children[0], in: raw), as: UTF8.self),
                       "never closed")
    }

    // MARK: - Limits

    func testNestingAndPartCountAreBounded() {
        var message = "Content-Type: text/plain\n\nleaf"
        for depth in 0..<(RawMIME.maxDepth + 8) {
            message = "Content-Type: multipart/mixed; boundary=b\(depth)\n\n--b\(depth)\n\(message)\n--b\(depth)--"
        }
        var node = RawMIME.parse(Data(message.utf8))
        var depth = 0
        while let child = node.children.first {
            node = child
            depth += 1
        }
        XCTAssertEqual(depth, RawMIME.maxDepth)

        let many: String = "Content-Type: multipart/mixed; boundary=m\n\n"
            + String(repeating: "--m\n\nx\n", count: RawMIME.maxParts * 2) + "--m--"
        let wide = RawMIME.parse(Data(many.utf8))
        XCTAssertLessThan(wide.children.count, RawMIME.maxParts)
    }

    // MARK: - Transfer encodings

    func testQuotedPrintable() {
        XCTAssertEqual(RawMIME.decodeQuotedPrintable(Data("a=3Db=20\r\nsoft=\r\nbreak=\nx=ZZ=4".utf8)),
                       Data("a=b \r\nsoftbreakx=ZZ=4".utf8))
        XCTAssertEqual(RawMIME.decodeQuotedPrintable(Data("end=".utf8)), Data("end".utf8))
        XCTAssertEqual(RawMIME.decodeQuotedPrintable(Data("caf=C3=A9".utf8)), Data("café".utf8))
    }
}
