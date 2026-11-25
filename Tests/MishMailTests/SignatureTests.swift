import XCTest
import GRDB

/// Signatures per account: storage (v63) and removal with the account, the
/// default rules (new, reply, forward, send-as address), the compose block
/// (insert, swap on From change, user edits left alone, manual choice, "No
/// signature", drafts opened again) and the import of a Gmail signature.
final class SignatureTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    private func insertAccount(_ db: Database, _ id: String) throws {
        try Account(id: id, displayName: id, historyId: nil,
                    lastSyncAt: nil, senderName: "").insert(db)
    }

    private func signature(_ id: Int64, _ body: String,
                           account: String = "a@x.com") -> SignatureRecord {
        SignatureRecord(id: id, accountId: account, name: "S\(id)", body: body,
                        createdAt: Date(timeIntervalSince1970: 0))
    }

    private func message(html: String?) -> Message {
        Message(id: "a@x.com:m1", accountId: "a@x.com", gmailId: "m1", threadId: "a@x.com:t1",
                fromHeader: "Jane <j@y.com>", toHeader: "a@x.com", ccHeader: "",
                subject: "Hi", date: Date(timeIntervalSince1970: 1_800_000_000),
                snippet: "", bodyText: "Original text", bodyHTML: html,
                messageIdHeader: "<m1@y.com>", referencesHeader: "", labelIds: "INBOX",
                isUnread: false, hasAttachment: false)
    }

    // MARK: - Migration and storage

    func testMigrationCreatesTheSignatureTables() throws {
        let q = try makeDB()
        try q.read { db in
            XCTAssertTrue(try AppDatabase.migrator.appliedIdentifiers(db).contains("v63"))
            XCTAssertTrue(try db.tableExists("signature"))
            XCTAssertTrue(try db.tableExists("signatureDefault"))
        }
    }

    func testSignaturesAreStoredPerAccount() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            try self.insertAccount(db, "b@x.com")
            try SignatureStore.insert(db, accountId: "a@x.com", name: "Work", body: "Ann\n**Uni**")
            try SignatureStore.insert(db, accountId: "a@x.com", name: "Short", body: "A.")
            try SignatureStore.insert(db, accountId: "b@x.com", name: "Bob", body: "Bob")
        }
        let book = try q.read { try SignatureStore.load($0) }
        XCTAssertEqual(book.signatures(for: "a@x.com").map(\.name), ["Short", "Work"])
        XCTAssertEqual(book.signatures(for: "B@X.com").map(\.body), ["Bob"])
    }

    func testRemovingTheAccountRemovesItsSignaturesAndDefaultsOnly() throws {
        let q = try makeDB()
        try q.write { db in
            for account in ["a@x.com", "b@x.com"] {
                try self.insertAccount(db, account)
                let row = try SignatureStore.insert(db, accountId: account, name: "S", body: "Sig")
                try SignatureStore.setDefault(db, accountId: account, email: account,
                                              use: .newMessage, choice: .signature(row.id!))
            }
            try AccountLifecycle.purgeAccount(db, id: "a@x.com")
        }
        try q.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT accountId FROM signature"),
                           ["b@x.com"])
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT accountId FROM signatureDefault"),
                           ["b@x.com"])
        }
    }

    func testDeletingTheAccountRowCascades() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            let row = try SignatureStore.insert(db, accountId: "a@x.com", name: "S", body: "Sig")
            try SignatureStore.setDefault(db, accountId: "a@x.com", email: "a@x.com",
                                          use: .reply, choice: .signature(row.id!))
            try db.execute(sql: "DELETE FROM account WHERE id = 'a@x.com'")
        }
        try q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM signature"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM signatureDefault"), 0)
        }
    }

    func testDeletingASignatureDropsTheDefaultsThatNamedIt() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            let row = try SignatureStore.insert(db, accountId: "a@x.com", name: "S", body: "Sig")
            try SignatureStore.setDefault(db, accountId: "a@x.com", email: "a@x.com",
                                          use: .newMessage, choice: .signature(row.id!))
            try SignatureStore.delete(db, id: row.id!)
        }
        let book = try q.read { try SignatureStore.load($0) }
        XCTAssertTrue(book.defaults.isEmpty)
        XCTAssertNil(book.defaultSignature(use: .newMessage, accountId: "a@x.com", email: "a@x.com"))
    }

    func testADefaultCannotNameAnotherAccountsSignature() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            try self.insertAccount(db, "b@x.com")
            let other = try SignatureStore.insert(db, accountId: "b@x.com", name: "B", body: "Bob")
            try SignatureStore.setDefault(db, accountId: "a@x.com", email: "a@x.com",
                                          use: .newMessage, choice: .signature(other.id!))
        }
        let book = try q.read { try SignatureStore.load($0) }
        XCTAssertTrue(book.defaults.isEmpty)
    }

    func testSavedTextIsNormalisedIntoOneBlock() {
        let clean = SignatureStore.normalized(name: "  Work\n", body: "-- \r\nAnn\r\n-- \r\nUni\n\n")
        XCTAssertEqual(clean.name, "Work")
        // The leading delimiter goes (MishMail adds its own); one inside
        // would split the block, so it loses its trailing space.
        XCTAssertEqual(clean.body, "Ann\n--\nUni")
        XCTAssertEqual(SignatureStore.normalized(name: " ", body: "x").name, "Signature")
        XCTAssertEqual(SignatureStore.normalized(
            name: "n", body: String(repeating: "a", count: 20_000)).body.count,
            SignatureStore.maxBodyLength)
    }

    // MARK: - Default rules

    private func book() -> SignatureBook {
        SignatureBook(
            signatures: [signature(1, "New"), signature(2, "Reply"), signature(3, "Alias"),
                         signature(9, "Other", account: "b@x.com")],
            defaults: [
                .init(accountId: "a@x.com", sendAsEmail: "a@x.com", use: "new", signatureId: 1),
                .init(accountId: "a@x.com", sendAsEmail: "a@x.com", use: "reply", signatureId: 2),
                .init(accountId: "a@x.com", sendAsEmail: "alias@x.com", use: "new", signatureId: 3),
                .init(accountId: "a@x.com", sendAsEmail: "quiet@x.com", use: "new", signatureId: nil),
            ])
    }

    func testNewMessageAndReplyDefaultsOfThePrimaryAddress() {
        let b = book()
        XCTAssertEqual(b.defaultSignature(use: .newMessage, accountId: "a@x.com",
                                          email: "A@x.com")?.id, 1)
        // Forwards use the reply default, like replies.
        XCTAssertEqual(b.defaultSignature(use: .reply, accountId: "a@x.com", email: "a@x.com")?.id, 2)
    }

    func testSendAsAddressHasItsOwnDefaultOrFollowsThePrimary() {
        let b = book()
        XCTAssertEqual(b.defaultSignature(use: .newMessage, accountId: "a@x.com",
                                          email: "alias@x.com")?.id, 3)
        // No reply choice for the alias: the primary's.
        XCTAssertEqual(b.defaultSignature(use: .reply, accountId: "a@x.com",
                                          email: "alias@x.com")?.id, 2)
        // "No signature" on purpose differs from the primary.
        XCTAssertNil(b.defaultSignature(use: .newMessage, accountId: "a@x.com",
                                        email: "quiet@x.com"))
        XCTAssertEqual(b.choice(use: .newMessage, accountId: "a@x.com", email: "quiet@x.com"), .none)
        XCTAssertEqual(b.choice(use: .reply, accountId: "a@x.com", email: "quiet@x.com"),
                       .followPrimary)
    }

    func testAnAccountWithoutDefaultsGetsNoSignature() {
        XCTAssertNil(book().defaultSignature(use: .newMessage, accountId: "b@x.com",
                                             email: "b@x.com"))
    }

    // MARK: - Compose block

    func testNewMessageGetsTheDefaultBelowAnEmptyBody() {
        var state = ComposeSignatureState()
        XCTAssertEqual(state.applyDefault(signature(1, "Ann\n**Uni**"), to: ""),
                       "\n\n-- \nAnn\n**Uni**")
        XCTAssertEqual(state.signatureId, 1)
    }

    func testFromChangeSwapsAnUntouchedSignature() throws {
        var state = ComposeSignatureState()
        let first = try XCTUnwrap(state.applyDefault(signature(1, "Ann"), to: ""))
        let typed = "Hello" + first
        XCTAssertEqual(state.applyDefault(signature(2, "Bob"), to: typed), "Hello\n\n-- \nBob")
        XCTAssertEqual(state.signatureId, 2)
        // To a sender with no default: removed, the user's text kept.
        XCTAssertEqual(state.applyDefault(nil, to: "Hello\n\n-- \nBob"), "Hello")
        XCTAssertNil(state.block)
        // And back.
        XCTAssertEqual(state.applyDefault(signature(1, "Ann"), to: "Hello"), "Hello\n\n-- \nAnn")
    }

    func testFromChangeLeavesAnEditedSignatureAlone() throws {
        var state = ComposeSignatureState()
        let first = try XCTUnwrap(state.applyDefault(signature(1, "Ann"), to: ""))
        XCTAssertNil(state.applyDefault(signature(2, "Bob"), to: "Hi" + first + " (mobile)"))
        XCTAssertNil(state.applyDefault(signature(2, "Bob"), to: "Hi\n\n-- \nAnnie"))
        // Removed by the user: not put back.
        XCTAssertNil(state.applyDefault(signature(2, "Bob"), to: "Hi"))
    }

    func testASignatureTheUserTypedIsLeftAlone() {
        var state = ComposeSignatureState()
        XCTAssertNil(state.applyDefault(signature(1, "Ann"), to: "Hi\n\n-- \nmy own"))
    }

    func testManualChoiceReplacesTheSignatureEvenWhenEdited() throws {
        var state = ComposeSignatureState()
        let first = try XCTUnwrap(state.applyDefault(signature(1, "Ann"), to: ""))
        XCTAssertEqual(state.choose(signature(2, "Bob"), in: "Hi" + first + " edited"),
                       "Hi\n\n-- \nBob")
        XCTAssertEqual(state.signatureId, 2)
        // With no signature in the body, the choice is appended.
        var fresh = ComposeSignatureState()
        XCTAssertEqual(fresh.choose(signature(1, "Ann"), in: "Hi"), "Hi\n\n-- \nAnn")
    }

    func testNoSignatureRemovesOnlyTheBlock() throws {
        var state = ComposeSignatureState()
        let first = try XCTUnwrap(state.applyDefault(signature(1, "Ann"), to: ""))
        XCTAssertEqual(state.choose(nil, in: "Dear Bob,\n\nSee you." + first), "Dear Bob,\n\nSee you.")
        XCTAssertNil(state.block)
        XCTAssertNil(state.signatureId)
    }

    func testADraftOpenedAgainKeepsItsBodyAndKnowsItsSignature() {
        let saved = "Hello\n\n-- \nAnn\n"
        let state = ComposeSignatureState.restored(head: saved,
                                                   among: [signature(1, "Ann"), signature(2, "Bob")])
        XCTAssertEqual(state.signatureId, 1)
        XCTAssertEqual(state.block, "\n\n-- \nAnn")
        // Its signature swaps like one just inserted once the user picks
        // another sender.
        var next = state
        XCTAssertEqual(next.applyDefault(signature(2, "Bob"), to: saved), "Hello\n\n-- \nBob")
        // Unknown signature text: the user's own.
        XCTAssertNil(ComposeSignatureState.restored(head: "Hi\n\n-- \nMine",
                                                    among: [signature(1, "Ann")]).block)
    }

    // MARK: - Outgoing HTML

    func testHTMLWrapsTheSignatureInGmailsBlock() {
        let html = ComposeQuote.authoredHeadHTML("Hello\n\n-- \nAnn\n**Uni**")
        XCTAssertTrue(html.contains("Hello"))
        XCTAssertTrue(html.contains(
            "<div class=\"gmail_signature\" data-smartmail=\"gmail_signature\">-- <br>"))
        XCTAssertTrue(html.contains("<strong>Uni</strong>"))
        let signatureStart = html.range(of: "gmail_signature")!.lowerBound
        XCTAssertTrue(html.range(of: "Hello")!.lowerBound < signatureStart)
    }

    func testReplySignatureSitsAboveTheQuote() throws {
        let html = ReplyComposer.htmlBody(userText: "Thanks\n\n-- \nAnn",
                                          original: message(html: "<p>Original</p>"))
        let signature = try XCTUnwrap(html.range(of: "gmail_signature\" data-smartmail"))
        let quote = try XCTUnwrap(html.range(of: "class=\"gmail_quote\""))
        XCTAssertTrue(signature.lowerBound < quote.lowerBound)
    }

    func testSignatureTextIsEscapedInHTML() {
        let html = ComposeQuote.authoredHeadHTML("Hi\n\n-- \n<script>alert(1)</script> <b onclick=x>")
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("<b "))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testABodyWithoutDelimiterRendersAsBefore() {
        XCTAssertEqual(ComposeQuote.authoredHeadHTML("Hello -- there"),
                       ComposeQuote.authoredHeadHTML("Hello -- there"))
        XCTAssertFalse(ComposeQuote.authoredHeadHTML("Hello -- there").contains("gmail_signature"))
    }

    // MARK: - Import from Gmail

    func testGmailSignatureKeepsTextFormattingAndSafeLinks() {
        let result = SignatureImport.markdown(fromGmailHTML: """
            <div dir="ltr"><b>Ann  Lee</b><br><i>Uni</i> &amp; co<br>\
            <a href="https://uni.example/a b">site</a> · <a href="mailto:ann@uni.example">mail</a>\
            <ul><li>one</li><li>two</li></ul></div>
            """)
        XCTAssertEqual(result.body, """
            **Ann Lee**
            *Uni* & co
            [site](https://uni.example/a%20b) · [mail](mailto:ann@uni.example)
            - one
            - two
            """)
        XCTAssertEqual(result.droppedImages, 0)
    }

    func testGmailSignatureLosesScriptsHandlersFormsAndImages() {
        let result = SignatureImport.markdown(fromGmailHTML: """
            <div onmouseover="steal()">Ann<script>alert(1)</script>\
            <style>div{background:url(https://t.example/x)}</style>\
            <a href="javascript:alert(2)">click</a>\
            <form action="https://evil.example"><input name="p"><button>Go</button></form>\
            <img src="https://t.example/logo.png" onerror="x()">\
            <a href="https://uni.example"><img src="https://t.example/b.png"></a></div>
            """)
        XCTAssertEqual(result.body, "Ann click")
        XCTAssertEqual(result.droppedImages, 2)
        let html = ComposeQuote.authoredHeadHTML("\n\n-- \n" + result.body)
        for banned in ["<script", "onmouseover", "javascript:", "<form", "<input", "<img",
                       "t.example", "evil.example"] {
            XCTAssertFalse(html.contains(banned), banned)
        }
    }

    func testGmailSignatureStartingWithADelimiterIsNotDoubled() {
        XCTAssertEqual(SignatureImport.markdown(fromGmailHTML: "-- <br>Ann").body, "Ann")
    }
}
