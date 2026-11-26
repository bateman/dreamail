import XCTest
import GRDB

/// A signature pasted into Settings → Signatures keeps its look through the
/// same path as one Gmail returns (`SignaturePaste`): text by
/// `SignatureImport`, look by `SignatureHTML`. It is a local signature.
final class SignaturePasteTests: XCTestCase {
    private let a = "ada@example.com"

    /// What a browser puts on the pasteboard when the signature is copied
    /// from Gmail's settings page (fictional data): a charset meta, the
    /// fragment markers, Gmail's editor container with classes and ids,
    /// and an image.
    static let copiedFromGmail = """
        <meta charset='utf-8'><html><body><!--StartFragment--><div id=":1x" class="Am aiL Al editable LW-avf tS-tW" \
        style="direction: ltr;" aria-label="Signature"><div dir="ltr" class="gmail_signature">\
        <div style="font-family:Arial,Helvetica,sans-serif;font-size:16px;font-weight:bold;color:#1a73e8">Ada Example</div>\
        <div style="color:#666666"><b>Research Engineer</b> | Example Lab</div>\
        <div><a href="https://www.example.com" class="x_link" id="l1" style="color:#1155cc" \
        onclick="alert(1)">www.example.com</a></div>\
        <img src="https://example.com/logo.png" width="80" height="20"></div></div><!--EndFragment--></body></html>
        """

    func testACopiedGmailSignatureKeepsItsLookAndLosesTheRest() throws {
        let pasted = try XCTUnwrap(SignaturePaste.read(html: Self.copiedFromGmail))
        XCTAssertTrue(pasted.body.contains("Ada Example"))
        XCTAssertTrue(pasted.body.contains("**Research Engineer** | Example Lab"))
        XCTAssertTrue(pasted.body.contains("[www.example.com](https://www.example.com)"))
        XCTAssertFalse(pasted.body.contains("<"))
        let html = try XCTUnwrap(pasted.html).lowercased()
        XCTAssertTrue(html.contains("ada example"))
        XCTAssertTrue(html.contains("color:#1a73e8"))
        XCTAssertTrue(html.contains("<b>research engineer</b>"))
        XCTAssertTrue(html.contains("href=\"https://www.example.com\""))
        for gone in ["class=", " id=", "aria-label", "onclick", "<img", "logo.png", "<meta",
                     "startfragment", "endfragment", "<!--", "<html", "<body"] {
            XCTAssertFalse(html.contains(gone), "\(gone) should not survive: \(html)")
        }
        XCTAssertEqual(pasted.droppedImages, 1)
        XCTAssertEqual(pasted.note, "1 image was left out.")
        // The stored look is a fixed point of the sanitiser.
        XCTAssertEqual(SignatureHTML.sanitize(try XCTUnwrap(pasted.html))?.html, pasted.html)
    }

    func testARefusedLookKeepsTheTextAndSaysSo() throws {
        let deep = String(repeating: "<div>", count: SignatureHTML.maxDepth + 6) + "Ada Example"
            + String(repeating: "</div>", count: SignatureHTML.maxDepth + 6)
        let pasted = try XCTUnwrap(SignaturePaste.read(html: deep))
        XCTAssertEqual(pasted.body, "Ada Example")
        XCTAssertNil(pasted.html)
        XCTAssertEqual(pasted.note, "The formatting could not be kept; the text was pasted.")
    }

    func testTooLargeOrEmptyHTMLFallsBackToAPlainPaste() {
        let large = "<div>" + String(repeating: "a", count: SignatureImport.maxInputLength) + "</div>"
        XCTAssertNil(SignaturePaste.read(html: large), "over 10,000 once reduced")
        XCTAssertNil(SignaturePaste.read(html: "<div>" + String(repeating: "a", count: SignaturePaste.maxRawLength) + "</div>"))
        XCTAssertNil(SignaturePaste.read(html: "<meta charset='utf-8'><img src=\"https://example.com/x.png\">"))
        XCTAssertNil(SignaturePaste.read(html: "<script>alert('Ada')</script>"))
    }

    /// R4: what Chrome or Safari put on the pasteboard: every element with
    /// about 1 KB of computed style, far over 10,000 characters in all. The
    /// reduction keeps the look, quickly.
    static func browserCopy() -> String {
        let computed = (0..<40).map { "-webkit-property-\($0): initial" }.joined(separator: "; ")
            + "; font-variant-ligatures: normal; orphans: 2; widows: 2; text-decoration-thickness: initial"
        func element(_ tag: String, _ kept: String, _ inner: String) -> String {
            "<\(tag) class=\"gmail_x\" style=\"\(computed); \(kept)\">\(inner)</\(tag)>"
        }
        var rows = ""
        for i in 0..<40 {
            rows += element("div", "color: #666666; font-size: 12px", "Example Lab line \(i)")
        }
        let html = "<meta charset='utf-8'><!--StartFragment-->"
            + element("div", "font-family: &quot;Helvetica Neue&quot;, Arial; font-weight: bold; color: #1a73e8",
                      "Ada Example")
            + rows
            + "<div><a href=\"https://www.example.com\" style=\"\(computed); color: #1155cc\">www.example.com</a></div>"
            + "<!--EndFragment-->"
        return html
    }

    func testABrowserCopyWithLongComputedStylesKeepsItsLook() throws {
        let html = Self.browserCopy()
        XCTAssertGreaterThan(html.utf16.count, 50_000)
        // Read raw, it would be over Gmail's limit and refused.
        XCTAssertEqual(GmailSignature.from(html: html), .unusable(reason: "too large"))
        let start = Date()
        let pasted = try XCTUnwrap(SignaturePaste.read(html: html))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the paste took too long")
        let look = try XCTUnwrap(pasted.html).lowercased()
        XCTAssertTrue(look.contains("color:#1a73e8"))
        // The declaration after a quoted font name survives the entity's ";".
        XCTAssertTrue(look.contains("font-weight:bold"))
        XCTAssertTrue(look.contains("helvetica neue"), look)
        XCTAssertTrue(look.contains("color:#666666"))
        XCTAssertFalse(look.contains("webkit"))
        XCTAssertFalse(look.contains("class="))
        XCTAssertTrue(pasted.body.contains("Ada Example"))
        XCTAssertTrue(pasted.body.contains("[www.example.com](https://www.example.com)"))
        XCTAssertNil(pasted.note)
    }

    /// Under 10,000 characters, reducing first changes nothing the
    /// sanitiser or the text import produce.
    func testReducingFirstGivesTheSameResultForSmallInput() throws {
        let fragments = [
            SignatureHTMLTests.lookAlike,
            Self.copiedFromGmail,
            "<div style=\"font-family: &quot;Google Sans&quot;, Roboto; font-size: small; color: #222222\">"
                + "<b>Ada Example</b> &amp; Example Lab<br><a href=\"https://example.com/?a=1&amp;b=2\">site</a></div>",
        ]
        for html in fragments {
            XCTAssertLessThan(html.utf16.count, SignatureImport.maxInputLength)
            let reduced = try XCTUnwrap(SignaturePaste.reduce(html))
            XCTAssertEqual(SignatureHTML.sanitize(reduced)?.html, SignatureHTML.sanitize(html)?.html, html)
            XCTAssertEqual(SignatureImport.markdown(fromGmailHTML: reduced),
                           SignatureImport.markdown(fromGmailHTML: html), html)
        }
    }

    /// Round 2, F4: `prepare` stays linear at the paste bound.
    func testPrepareIsLinearAtThePasteBound() {
        let inputs = [
            String(repeating: "<![]>", count: 60_000),
            String(repeating: "<!---->", count: 42_857),
            String(repeating: "<script></script>", count: 17_600),
        ]
        for html in inputs {
            XCTAssertLessThanOrEqual(html.utf8.count, SignaturePaste.maxRawLength)
            let start = Date()
            _ = SignatureHTML.prepare(html)
            _ = SignaturePaste.read(html: html)
            XCTAssertLessThan(Date().timeIntervalSince(start), 5, "\(html.prefix(12)) took too long")
        }
    }

    func testTheClosingTagScanIgnoresCase() {
        let text = Substring("<p>a</SCRIPT x>b")
        let end = SignatureHTML.closingTag("script", in: text)
        XCTAssertEqual(end.map { String(text[$0...]) }, " x>b")
        XCTAssertNil(SignatureHTML.closingTag("style", in: text))
    }

    func testTheReductionKeepsOnlyAllowedAttributesAndDeclarations() throws {
        let reduced = try XCTUnwrap(SignaturePaste.reduce(
            "<!--x--><DIV id=a CLASS='b' onclick=\"c()\" dir=ltr style='color: red; position: absolute;"
            + " font-weight:bold'>t</DIV><a href=\"https://example.com\" target=_blank>l</a>"
            + "<script>alert(1)</script><img src=x/>"))
        XCTAssertEqual(reduced, "<div dir=\"ltr\" style=\"color: red; font-weight:bold\">t</div>"
            + "<a href=\"https://example.com\">l</a> <img>")
        XCTAssertNil(SignaturePaste.reduce(String(repeating: "a", count: SignaturePaste.maxRawLength + 1)))
        // Hostile shapes stay linear.
        let start = Date()
        _ = SignaturePaste.read(html: "<div style=\"" + String(repeating: "rgb(", count: 70_000) + "\">x</div>")
        _ = SignaturePaste.read(html: String(repeating: "<div a=\"", count: 30_000))
        _ = SignaturePaste.read(html: String(repeating: "<b>", count: 90_000))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    // MARK: - Stored as a local rich signature

    private func database() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.a, displayName: self.a, historyId: nil, lastSyncAt: nil,
                        senderName: "").insert(db)
        }
        return q
    }

    func testAPastedSignatureIsLocalRichAndUsedLikeAnyRichOne() throws {
        let q = try database()
        let pasted = try XCTUnwrap(SignaturePaste.read(html: Self.copiedFromGmail))
        let row = try q.write {
            try SignatureStore.insert($0, accountId: self.a, name: "Lab", body: pasted.body,
                                      html: pasted.html)
        }
        XCTAssertNil(row.gmailAddress)
        XCTAssertFalse(row.editedHere)
        XCTAssertEqual(row.html, pasted.html)
        // The import of another Gmail signature leaves it alone.
        try q.write { db in
            _ = try SignatureStore.applyGmail(db, accountId: self.a,
                                              gmail: [self.a: .text("Ada", html: "<b>Ada</b>")])
        }
        let stored = try XCTUnwrap(try q.read { try SignatureStore.load($0) }.signature(id: XCTUnwrap(row.id)))
        XCTAssertEqual(stored.html, pasted.html)
        XCTAssertEqual(stored.body, pasted.body)
        XCTAssertNil(stored.gmailAddress)
        // Downstream: compose shows it rendered and sends its look once.
        let id = try XCTUnwrap(ComposeSignature.richId(of: stored))
        let body = ComposeSignature.assembled(body: "Hello", signature: stored)
        let html = try XCTUnwrap(OutgoingHTML.build(body: body, forwardOf: nil, replyTo: nil, draft: nil,
                                                    threadMessages: [], signatures: [stored],
                                                    style: .rich(id))).lowercased()
        XCTAssertEqual(html.components(separatedBy: "color:#1a73e8").count - 1, 1)
    }

    func testTheLookIsSanitisedAgainAtTheStore() throws {
        let q = try database()
        let row = try q.write {
            try SignatureStore.insert($0, accountId: self.a, name: "X", body: "Ada",
                                      html: "<b onclick=\"x()\">Ada</b><img src=\"https://example.com/a.png\">")
        }
        XCTAssertEqual(row.html, "<b>Ada</b>")
    }

    func testEditingSettingAndRemovingTheLook() throws {
        let q = try database()
        let row = try q.write {
            try SignatureStore.insert($0, accountId: self.a, name: "Lab", body: "Ada")
        }
        let id = try XCTUnwrap(row.id)
        func load() throws -> SignatureRecord {
            try XCTUnwrap(try q.read { try SignatureStore.load($0) }.signature(id: id))
        }
        try q.write { try SignatureStore.update($0, id: id, name: "Lab", body: "Ada", look: .set("<b>Ada</b>")) }
        XCTAssertEqual(try load().html, "<b>Ada</b>")
        // A rename keeps it.
        try q.write { try SignatureStore.update($0, id: id, name: "Lab 2", body: "Ada") }
        XCTAssertEqual(try load().html, "<b>Ada</b>")
        // A text edit drops it, as in compose.
        try q.write { try SignatureStore.update($0, id: id, name: "Lab 2", body: "Ada E.") }
        XCTAssertNil(try load().html)
        // "Remove formatting".
        try q.write { try SignatureStore.update($0, id: id, name: "Lab 2", body: "Ada E.", look: .set("<i>Ada E.</i>")) }
        XCTAssertNotNil(try load().html)
        try q.write { try SignatureStore.update($0, id: id, name: "Lab 2", body: "Ada E.", look: .remove) }
        XCTAssertNil(try load().html)
        XCTAssertNil(try load().gmailAddress)
    }
}
