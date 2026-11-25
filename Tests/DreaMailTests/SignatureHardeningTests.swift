import XCTest
import GRDB

/// Review round 1 on the Gmail look (#79): the swap only in the authored
/// head (reply, forward, draft opened again, through `OutgoingHTML`), and
/// the sanitiser against slow, deep and overlapping input.
final class SignatureHardeningTests: XCTestCase {
    private let a = "ann@example.com"

    /// A Gmail copy with its look, as the sync stores it.
    private func gmailCopy() throws -> SignatureRecord {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: self.a, displayName: self.a, historyId: nil, lastSyncAt: nil,
                        senderName: "").insert(db)
            try SignatureStore.applyGmail(
                db, accountId: self.a,
                gmail: [self.a: XCTUnwrap(GmailSignature.from(html: SignatureHTMLTests.lookAlike))])
        }
        return try XCTUnwrap(try q.read { try SignatureStore.load($0) }.signatures(for: a).first)
    }

    /// A message DreaMail sent before #79: its signature is the plain block.
    private func earlierMessage(signature: SignatureRecord) -> Message {
        let html = ComposeQuote.authoredHeadHTML("Earlier\n\n-- \n" + signature.body)
        return Message(id: "\(a):m1", accountId: a, gmailId: "m1", threadId: "\(a):t1",
                       fromHeader: "Ann <\(a)>", toHeader: "bob@example.com", ccHeader: "",
                       subject: "Plan", date: Date(timeIntervalSince1970: 1_800_000_000),
                       snippet: "", bodyText: "Earlier\n\n-- \n" + signature.body, bodyHTML: html,
                       messageIdHeader: "<m1@example.com>", referencesHeader: "",
                       labelIds: "INBOX", isUnread: false, hasAttachment: false)
    }

    private func head(_ signature: SignatureRecord) -> String {
        "Hello Bob\n\n-- \n" + signature.body
    }

    /// The rich look sits before the quote; the quote keeps its plain block.
    private func assertSwappedInHeadOnly(_ html: String?, signature: SignatureRecord,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        let html = try XCTUnwrap(html, file: file, line: line)
        let quote = try XCTUnwrap(html.range(of: "<div class=\"gmail_quote\""),
                                  "no quote in \(html)", file: file, line: line)
        let before = String(html[..<quote.lowerBound]), after = String(html[quote.lowerBound...])
        XCTAssertTrue(before.lowercased().contains("border-right:3px solid #6aa84f"),
                      "the new signature should carry Gmail's look", file: file, line: line)
        XCTAssertTrue(after.contains(ComposeQuote.signatureBlockHTML(signature.body)),
                      "the quoted message must stay as it was", file: file, line: line)
        XCTAssertFalse(after.lowercased().contains("border-right:3px"), file: file, line: line)
    }

    func testAReplyGetsTheLookInItsHeadNotInTheQuote() throws {
        let signature = try gmailCopy()
        let original = earlierMessage(signature: signature)
        let body = head(signature) + "\n" + ReplyComposer.plainQuote(of: original)
        let html = OutgoingHTML.build(body: body, forwardOf: nil, replyTo: original, draft: nil,
                                      threadMessages: [], signatures: [signature])
        try assertSwappedInHeadOnly(html, signature: signature)
    }

    func testAForwardGetsTheLookInItsHeadNotInTheQuote() throws {
        let signature = try gmailCopy()
        let original = earlierMessage(signature: signature)
        let body = head(signature) + "\n\n"
            + ForwardComposer.forwardBlock(parts: [ForwardComposer.Part(message: original)])
        let html = OutgoingHTML.build(body: body, forwardOf: original, replyTo: nil, draft: nil,
                                      threadMessages: [original], signatures: [signature])
        try assertSwappedInHeadOnly(html, signature: signature)
    }

    func testADraftOpenedAgainUnchangedGetsTheLookInItsHead() throws {
        let signature = try gmailCopy()
        let original = earlierMessage(signature: signature)
        let body = head(signature) + "\n" + ReplyComposer.plainQuote(of: original)
        // Saved before #79: the plain block in its head and in its quote.
        let plain = ReplyComposer.htmlBody(userText: head(signature), original: original)
        var draft = original
        draft.bodyText = body
        draft.bodyHTML = plain
        let html = OutgoingHTML.build(body: body, forwardOf: nil, replyTo: nil, draft: draft,
                                      threadMessages: [], signatures: [signature])
        try assertSwappedInHeadOnly(html, signature: signature)
    }

    // MARK: - Slow input (R5)

    private func assertQuick(_ label: String, _ work: () -> Void) {
        let start = Date()
        work()
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "\(label) took too long")
    }

    func testOpenersWithoutAnEndAreQuick() {
        let inputs = [
            "comments": String(repeating: "<!--", count: 2_500),
            "scripts": String(repeating: "<script>", count: 1_250),
            "declarations": String(repeating: "<!x", count: 3_300),
            "tags": String(repeating: "<a href=x", count: 1_100),
            "bold": String(repeating: "<b>", count: 3_300),
        ]
        for (label, html) in inputs {
            XCTAssertLessThanOrEqual(html.utf16.count, SignatureImport.maxInputLength)
            assertQuick(label) { _ = GmailSignature.from(html: html) }
        }
    }

    func testInputOverGmailsLimitIsRefusedAtOnce() {
        let html = String(repeating: "<!--", count: 12_500)
        assertQuick("oversized") {
            XCTAssertEqual(GmailSignature.from(html: html), .unusable(reason: "too large"))
            XCTAssertNil(SignatureHTML.sanitize(html))
        }
        XCTAssertEqual(SignatureImport.maxInputLength, 10_000)
    }

    // MARK: - Deep nesting (R6)

    private final class Outcome: @unchecked Sendable {
        var deep: SignatureHTML.Result?
        var shallow: SignatureHTML.Result?
    }

    private static let tooDeep = String(repeating: "<div>", count: 1_900) + "x"
    private static let justDeepEnough = String(repeating: "<div>", count: 60) + "Ann"
        + String(repeating: "</div>", count: 60)

    func testDeepNestingIsRefusedOnTheMainThread() {
        XCTAssertNil(SignatureHTML.sanitize(Self.tooDeep))
        XCTAssertNil(SignatureHTML.sanitize(String(repeating: "<b>", count: 65) + "x"))
        XCTAssertNotNil(SignatureHTML.sanitize(Self.justDeepEnough))
    }

    func testDeepNestingIsRefusedOnABackgroundThread() {
        let outcome = Outcome()
        let done = expectation(description: "background sanitise")
        // A secondary thread's default stack is much smaller than the main one's.
        let thread = Thread {
            outcome.deep = SignatureHTML.sanitize(Self.tooDeep)
            outcome.shallow = SignatureHTML.sanitize(Self.justDeepEnough)
            done.fulfill()
        }
        thread.start()
        wait(for: [done], timeout: 30)
        XCTAssertNil(outcome.deep)
        XCTAssertTrue(outcome.shallow?.html.contains("Ann") ?? false)
    }

    // MARK: - Overlap (R7)

    func testNothingPullsTheSignatureOverTheTextAroundIt() {
        XCTAssertEqual(SignatureHTML.filterStyle("height:0"), "")
        XCTAssertEqual(SignatureHTML.filterStyle("max-height:0"), "")
        XCTAssertEqual(SignatureHTML.filterStyle("text-indent:-9999px"), "")
        XCTAssertEqual(SignatureHTML.filterStyle("letter-spacing:-1em"), "")
        XCTAssertEqual(SignatureHTML.filterStyle("line-height:0"), "")
        XCTAssertEqual(SignatureHTML.filterStyle("line-height:0.5"), "")
        XCTAssertEqual(SignatureHTML.filterStyle("margin:0 -5px"), "")
        XCTAssertEqual(SignatureHTML.filterStyle("padding:0 0 -.5em"), "")
        XCTAssertEqual(SignatureHTML.filterStyle("font:12px/0 Arial"), "")
        // What is ordinary stays.
        XCTAssertEqual(SignatureHTML.filterStyle("line-height:1.4"), "line-height:1.4")
        XCTAssertEqual(SignatureHTML.filterStyle("line-height:18px"), "line-height:18px")
        XCTAssertEqual(SignatureHTML.filterStyle("font-family:sans-serif"), "font-family:sans-serif")
        XCTAssertEqual(SignatureHTML.filterStyle("text-indent:4px"), "text-indent:4px")

        let html = SignatureHTML.sanitize(
            "<div style=\"height:0;color:#000\" height=\"0\">Ann Example, a line long enough to overflow</div>"
            + "<table><tr><td height=\"20\">cell</td></tr></table>")?.html ?? ""
        XCTAssertFalse(html.contains("height:0"))
        XCTAssertFalse(html.contains("height=\"0\""))
        XCTAssertTrue(html.contains("Ann Example"))
        XCTAssertTrue(html.contains("height=\"20\""), "a table cell keeps its height attribute")
    }

    // MARK: - Declarations (S1)

    func testDeclarationsAndTheirEntitiesAreDropped() throws {
        let html = try XCTUnwrap(SignatureHTML.sanitize(
            "<!DOCTYPE html [<!ENTITY e \"EVIL\"> <!ENTITY f SYSTEM \"https://tracker.example.net/x\">]>"
            + "<?xml version=\"1.0\"?><div>Ann &e; &f;</div>")).html
        for banned in ["EVIL", "DOCTYPE", "ENTITY", "tracker", "<?xml"] {
            XCTAssertFalse(html.contains(banned), "\(banned) survived in \(html)")
        }
        XCTAssertTrue(html.contains("Ann"))
        XCTAssertEqual(GmailSignature.from(html: "<!DOCTYPE html><div>Ann</div>").map {
            if case .text(let body, _, _, _) = $0 { return body } else { return "" }
        }, "Ann")
    }
}
