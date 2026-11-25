import XCTest
import GRDB

/// Gmail's look survives (`SignatureHTML`): a signature shaped like a real
/// one (bold name, grey title line, green labels, blue links, a 3 px green
/// bar on the right) goes through import → store → compose HTML → the HTML
/// that is sent, with its styles intact; a hostile one loses everything
/// that could run, load or escape.
final class SignatureHTMLTests: XCTestCase {
    /// Look-alike fixture (fictional data, example.com).
    static let lookAlike = """
        <div dir="ltr"><table cellpadding="0" cellspacing="0" style="border-collapse:collapse">\
        <tbody><tr><td style="padding:0 12px 0 0;border-right:3px solid #6aa84f">\
        <div style="font-family:Arial,Helvetica,sans-serif;font-size:18px;font-weight:bold;color:#000000">Ann Example</div>\
        <div style="font-family:Arial,sans-serif;font-size:13px;color:#666666"><b>Research Engineer</b> | Example Lab</div>\
        <div style="font-size:12px;color:#999999;line-height:1.4">Example University, Example City</div>\
        <div style="font-size:12px"><font color="#6aa84f"><b>site:</b></font> \
        <a href="https://www.example.com" style="color:#1155cc;text-decoration:underline">www.example.com</a></div>\
        <div style="font-size:12px"><span style="color:#6aa84f;font-weight:bold">email:</span> \
        <a href="mailto:ann@example.com" style="color:#1155cc">ann@example.com</a></div>\
        </td></tr></tbody></table></div>
        """

    static let preserved = [
        "border-right:3px solid #6aa84f",
        "padding:0 12px 0 0",
        "border-collapse:collapse",
        "font-size:18px", "font-weight:bold", "color:#000000",
        "font-family:Arial,Helvetica,sans-serif",
        "color:#666666", "color:#999999", "line-height:1.4",
        "color:#1155cc;text-decoration:underline",
        "<font color=\"#6aa84f\">", "<b>Research Engineer</b>",
        "cellpadding=\"0\"", "cellspacing=\"0\"",
        "href=\"https://www.example.com\"", "href=\"mailto:ann@example.com\"",
        "<table", "<td", "Ann Example", "Example Lab",
    ]

    private func assertPreserved(_ html: String, file: StaticString = #filePath, line: UInt = #line) {
        for piece in Self.preserved {
            XCTAssertTrue(html.contains(piece), "missing \(piece) in \(html)", file: file, line: line)
        }
    }

    func testTheLookAlikeSignatureKeepsItsStyles() throws {
        let result = try XCTUnwrap(SignatureHTML.sanitize(Self.lookAlike))
        assertPreserved(result.html)
        XCTAssertEqual(result.droppedImages, 0)
        // Rebuilding what was rebuilt changes nothing.
        XCTAssertEqual(SignatureHTML.sanitize(result.html)?.html, result.html)
    }

    func testTheLookSurvivesStoreComposeAndSend() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        let a = "ann@example.com"
        try q.write { db in
            try Account(id: a, displayName: a, historyId: nil, lastSyncAt: nil, senderName: "").insert(db)
            let gmail = try XCTUnwrap(GmailSignature.from(html: Self.lookAlike))
            try SignatureStore.applyGmail(db, accountId: a, gmail: [a: gmail])
        }
        let book = try q.read { try SignatureStore.load($0) }
        let signature = try XCTUnwrap(book.signatures(for: a).first)
        assertPreserved(try XCTUnwrap(signature.html))
        // Compose inserts the text block; the sent HTML carries Gmail's look.
        var state = ComposeSignatureState()
        let head = state.choose(signature, in: "Hello Bob", known: [signature.body])
        let plain = ComposeQuote.authoredHeadHTML(head)
        let sent = ComposeSignature.withRichSignature(plain, head: head,
                                                      signatures: book.signatures(for: a))
        assertPreserved(sent)
        XCTAssertTrue(sent.contains("gmail_signature"))
        XCTAssertTrue(sent.contains("Hello Bob"))
        // Exactly one signature, and no dark-mode colours added.
        XCTAssertEqual(sent.components(separatedBy: "class=\"gmail_signature\"").count - 1, 1)
        XCTAssertFalse(sent.contains("prefers-color-scheme"))
        // Edited in compose: it goes out as the text the user sees.
        let edited = head + " (on leave)"
        XCTAssertEqual(ComposeSignature.withRichSignature(
            ComposeQuote.authoredHeadHTML(edited), head: edited, signatures: book.signatures(for: a)),
            ComposeQuote.authoredHeadHTML(edited))
        // Above a reply quote too.
        let reply = ReplyComposer.htmlBody(userText: head, original: Self.message())
        assertPreserved(ComposeSignature.withRichSignature(reply, head: head,
                                                           signatures: book.signatures(for: a)))
    }

    func testEditingTheTextHereDropsTheLookAndUseGmailsBringsItBack() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        let a = "ann@example.com"
        try q.write { db in
            try Account(id: a, displayName: a, historyId: nil, lastSyncAt: nil, senderName: "").insert(db)
            try SignatureStore.applyGmail(db, accountId: a,
                                          gmail: [a: XCTUnwrap(GmailSignature.from(html: Self.lookAlike))])
        }
        let id = try XCTUnwrap(try q.read { try SignatureStore.load($0) }.signatures(for: a).first?.id)
        try q.write { try SignatureStore.update($0, id: id, name: "Work", body: "Ann") }
        XCTAssertNil(try q.read { try SignatureStore.load($0) }.signature(id: id)?.html)
        try q.write { try SignatureStore.useGmailVersion($0, id: id) }
        assertPreserved(try XCTUnwrap(try q.read { try SignatureStore.load($0) }.signature(id: id)?.html))
    }

    func testAStyleOnlyChangeOnGmailIsFollowed() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        let a = "ann@example.com"
        try q.write { db in
            try Account(id: a, displayName: a, historyId: nil, lastSyncAt: nil, senderName: "").insert(db)
            try SignatureStore.applyGmail(db, accountId: a, gmail: [a: .text("Ann", html: "<b>Ann</b>")])
            let outcome = try SignatureStore.applyGmail(
                db, accountId: a, gmail: [a: .text("Ann", html: "<b style=\"color:#6aa84f\">Ann</b>")])
            XCTAssertEqual(outcome.updated, 1)
        }
        XCTAssertEqual(try q.read { try SignatureStore.load($0) }.signatures(for: a).first?.html,
                       "<b style=\"color:#6aa84f\">Ann</b>")
    }

    func testAHostileSignatureLosesEverythingThatCanRunLoadOrEscape() throws {
        let hostile = """
            <div onclick="steal()" class="x" id="y" style="position:absolute;top:0;\
            background:url(https://tracker.example.net/a.gif);color:red;width:expression(alert(1));\
            margin:-500px 0 0 0;behavior:url(x.htc);font-size:14px">Ann</div>\
            <script>alert(1)</script><style>body{display:none}</style>\
            <link rel="stylesheet" href="https://tracker.example.net/x.css">\
            <img src="https://tracker.example.net/p.gif" onerror="alert(1)">\
            <iframe src="https://tracker.example.net"></iframe>\
            <svg onload="alert(1)"><text>svg</text></svg>\
            <a href="javascript:alert(1)">js link</a> <a href="data:text/html,x">data link</a> \
            <a href="https://evil.example.net/login">https://bank.example.com</a> \
            <span style="color:#000;font-family:'Ann\\\\';x:expression(1)">quoted</span>\
            <span style="display:none">hidden</span> <font face="Arial" color="javascript:x">f</font>\
            <form action="https://tracker.example.net"><input name="p"></form>\
            &lt;b&gt;not a tag&lt;/b&gt;
            """
        let result = try XCTUnwrap(SignatureHTML.sanitize(hostile))
        let out = result.html.lowercased()
        for banned in ["onclick", "onerror", "onload", "class=", "id=", "position", "url(",
                       "expression", "behavior", "margin", "<script", "alert", "<style",
                       "<link", "<img", "<iframe", "<svg", "javascript:", "data:", "<form",
                       "<input", "tracker.example.net", "evil.example.net", "display:none",
                       "<b>not a tag"] {
            XCTAssertFalse(out.contains(banned), "\(banned) survived in \(result.html)")
        }
        XCTAssertEqual(result.droppedImages, 1)
        // What is harmless stays.
        XCTAssertTrue(out.contains("color:red"))
        XCTAssertTrue(out.contains("font-size:14px"))
        XCTAssertTrue(out.contains("js link"))
        XCTAssertTrue(out.contains("https://bank.example.com"))
        XCTAssertTrue(out.contains("&lt;b&gt;not a tag&lt;/b&gt;"))
        XCTAssertTrue(out.contains("face=\"arial\""))
    }

    func testStyleValuesAreFilteredOneByOne() {
        XCTAssertEqual(SignatureHTML.filterStyle("color: rgb(10, 20, 30); position: fixed; font-weight: 700"),
                       "color:rgb(10, 20, 30);font-weight:700")
        XCTAssertEqual(SignatureHTML.filterStyle("font-family: 'Google Sans', Roboto, sans-serif"),
                       "font-family:'Google Sans', Roboto, sans-serif")
        XCTAssertEqual(SignatureHTML.filterStyle("color: var(--x); width: calc(100% - 1px)"), "")
        XCTAssertEqual(SignatureHTML.filterStyle("display: table-cell; display: flex"),
                       "display:table-cell")
        XCTAssertEqual(SignatureHTML.filterStyle("border-right: 3px solid #6aa84f; max-width: 600px"),
                       "border-right:3px solid #6aa84f;max-width:600px")
        XCTAssertEqual(SignatureHTML.filterStyle("color:#000 \\9; content: 'x'"), "")
    }

    func testTooLargeOrEmptyKeepsNoLook() {
        XCTAssertNil(SignatureHTML.sanitize(String(repeating: "<b>x</b>", count: 10_000)))
        XCTAssertNil(SignatureHTML.sanitize("<img src=\"https://example.com/logo.png\">"))
    }

    private static func message() -> Message {
        Message(id: "ann@example.com:m1", accountId: "ann@example.com", gmailId: "m1",
                threadId: "ann@example.com:t1", fromHeader: "Bob <bob@example.com>",
                toHeader: "ann@example.com", ccHeader: "", subject: "Hi",
                date: Date(timeIntervalSince1970: 1_800_000_000), snippet: "",
                bodyText: "Original text", bodyHTML: "<div>Original text</div>",
                messageIdHeader: "<m1@example.com>", referencesHeader: "", labelIds: "INBOX",
                isUnread: false, hasAttachment: false)
    }
}
