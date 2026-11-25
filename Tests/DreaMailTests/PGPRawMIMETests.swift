import XCTest

/// The structure-only MIME reader under OpenPGP/MIME (step 4B), and above
/// all the exact signed bytes of a `multipart/signed` (RFC 3156 §5), which
/// is the part implementations usually get wrong. The bytes are observed
/// where they matter: what reaches the engine, and `signedContent`.
final class PGPRawMIMETests: XCTestCase {
    private struct NoVerification: Error {}

    /// The signed bytes and the signature as the engine receives them.
    private func engineInput(_ raw: Data) async throws -> (signed: Data, signature: Data, content: Data?) {
        let engine = FakeOpenPGPEngine()
        let security = await PGPInspection.security(ofRaw: raw, engine: engine, enabled: true)
        guard case .verifyDetached(let signed, let signature)? = engine.calls.first else {
            XCTFail("the engine was not asked to verify")
            throw NoVerification()
        }
        return (signed, signature, security?.signedContent)
    }

    // MARK: - Signed bytes

    func testSignedBytesAreTheFirstPartExactlyInCRLFForm() async throws {
        for raw in [PGPCorpus.crlf(PGPCorpus.signedSimple()), PGPCorpus.lf(PGPCorpus.signedSimple())] {
            let input = try await engineInput(raw)
            XCTAssertEqual(input.signed, PGPCorpus.signedPartCanonical,
                           String(decoding: input.signed, as: UTF8.self))
            XCTAssertEqual(input.content, PGPCorpus.signedPartCanonical, "what may be shown as signed")
            XCTAssertEqual(String(decoding: input.signature, as: UTF8.self)
                .replacingOccurrences(of: "\r\n", with: "\n"), PGPCorpus.fakeSignature)
        }
    }

    /// The CRLF before the next delimiter belongs to the delimiter: the
    /// signed bytes end at "Alice", not "Alice\r\n".
    func testTheLineBreakBeforeTheDelimiterIsNotSigned() async throws {
        let input = try await engineInput(PGPCorpus.crlf(PGPCorpus.signedSimple()))
        XCTAssertTrue(String(decoding: input.signed, as: UTF8.self).hasSuffix("\r\nAlice"))
        XCTAssertFalse(input.signed.starts(with: Data("\r\n".utf8)))
    }

    func testTransportPaddingAfterADelimiterIsAccepted() async throws {
        let input = try await engineInput(PGPCorpus.crlf(PGPCorpus.signedSimple(delimiterSuffix: " \t ")))
        XCTAssertEqual(input.signed, PGPCorpus.signedPartCanonical)
    }

    /// A line that only starts like the boundary is content, and the nested
    /// multipart is signed whole, inner boundaries included.
    func testNestedSignedPartAndBoundaryLookAlikes() async throws {
        for raw in [PGPCorpus.crlf(PGPCorpus.signedNested), PGPCorpus.lf(PGPCorpus.signedNested)] {
            let input = try await engineInput(raw)
            XCTAssertEqual(input.signed, PGPCorpus.signedNestedPartCanonical,
                           String(decoding: input.signed, as: UTF8.self))
        }
        let root = RawMIME.parse(PGPCorpus.crlf(PGPCorpus.signedNested))
        XCTAssertEqual(root.children.count, 2)
        XCTAssertEqual(root.children[0].children.count, 2)
        XCTAssertEqual(root.children[0].children[1].filename, "notes.txt")
        XCTAssertFalse(root.truncated)
        XCTAssertFalse(root.isAmbiguous)
    }

    /// Signed bytes are cut from the source unchanged: a part with mixed
    /// line endings keeps its CRLFs, gains CR only before bare LFs, and
    /// keeps a bare CR.
    func testCanonicalFormOnlyAddsCRBeforeBareLF() {
        XCTAssertEqual(RawMIME.canonicalCRLF(Data("a\r\nb\nc\rd\n\n".utf8)),
                       Data("a\r\nb\r\nc\rd\r\n\r\n".utf8))
        XCTAssertEqual(RawMIME.canonicalCRLF(Data("\nx".utf8)), Data("\r\nx".utf8))
        XCTAssertEqual(RawMIME.canonicalCRLF(Data()), Data())
        XCTAssertEqual(RawMIME.canonicalCRLF(Data("no breaks".utf8)), Data("no breaks".utf8))
        XCTAssertEqual(RawMIME.canonicalCRLF(Data("trailing  \n".utf8)),
                       Data("trailing  \r\n".utf8), "no whitespace stripping")
    }

    func testEncryptedPayloadIsTheOctetStreamBody() async {
        let engine = FakeOpenPGPEngine()
        _ = await PGPInspection.security(ofRaw: PGPCorpus.lf(PGPCorpus.encrypted), engine: engine,
                                         enabled: true)
        XCTAssertEqual(engine.calls, [.decrypt(Data((PGPCorpus.fakeMessage + "\n").utf8))])
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
        XCTAssertFalse(quoted.hasDuplicateParameters)
        XCTAssertFalse(quoted.hasExtendedParameters)

        let duplicate = MIMEContentType(headerValue: "multipart/mixed; boundary=first; boundary=second")
        XCTAssertEqual(duplicate.parameters["boundary"], "first", "a later duplicate must not win")
        XCTAssertTrue(duplicate.hasDuplicateParameters)

        let extended = MIMEContentType(headerValue: "multipart/mixed; boundary*0=\"a\"; boundary*1=\"b\"")
        XCTAssertTrue(extended.hasExtendedParameters)
        XCTAssertNil(extended.parameters["boundary"], "RFC 2231 is not decoded")

        for bad in [nil, "", "text", "/plain", "text/", "te xt/plain"] {
            XCTAssertEqual(MIMEContentType(headerValue: bad), .defaultText, String(describing: bad))
        }
    }

    func testAmbiguityIsRecorded() {
        for variant in ["two-content-types", "two-boundaries", "rfc2231-boundary"] {
            let root = RawMIME.parse(PGPCorpus.lf(PGPCorpus.signedAmbiguous(variant)))
            XCTAssertTrue(root.isAmbiguous, variant)
        }
        XCTAssertFalse(RawMIME.parse(PGPCorpus.lf(PGPCorpus.signedAmbiguous("two-froms"))).isAmbiguous)
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

    func testNestingAndPartCountAreBoundedAndMarked() {
        var message = "Content-Type: text/plain\n\nleaf"
        for depth in 0..<(RawMIME.maxDepth + 8) {
            message = "Content-Type: multipart/mixed; boundary=b\(depth)\n\n--b\(depth)\n\(message)\n--b\(depth)--"
        }
        var node = RawMIME.parse(Data(message.utf8))
        var depth = 0
        while let child = node.children.first {
            XCTAssertFalse(node.truncated)
            node = child
            depth += 1
        }
        XCTAssertEqual(depth, RawMIME.maxDepth)
        XCTAssertTrue(node.truncated, "the level not read is marked")

        let many: String = "Content-Type: multipart/mixed; boundary=m\n\n"
            + String(repeating: "--m\n\nx\n", count: RawMIME.maxParts * 2) + "--m--"
        let wide = RawMIME.parse(Data(many.utf8))
        XCTAssertLessThan(wide.children.count, RawMIME.maxParts)
        XCTAssertTrue(wide.truncated)
    }

    // MARK: - Transfer encodings

    func testQuotedPrintable() {
        XCTAssertEqual(RawMIME.decodeQuotedPrintable(Data("a=3Db=20\r\nsoft=\r\nbreak=\nx=ZZ=4".utf8)),
                       Data("a=b \r\nsoftbreakx=ZZ=4".utf8))
        XCTAssertEqual(RawMIME.decodeQuotedPrintable(Data("end=".utf8)), Data("end".utf8))
        XCTAssertEqual(RawMIME.decodeQuotedPrintable(Data("caf=C3=A9".utf8)), Data("café".utf8))
    }
}
