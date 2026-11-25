import XCTest
import AppKit
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

    func testDeletingASignatureMakesItsDefaultsNoSignature() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            let primary = try SignatureStore.insert(db, accountId: "a@x.com", name: "P", body: "Primary")
            let alias = try SignatureStore.insert(db, accountId: "a@x.com", name: "A", body: "Alias")
            try SignatureStore.setDefault(db, accountId: "a@x.com", email: "a@x.com",
                                          use: .newMessage, choice: .signature(primary.id!))
            try SignatureStore.setDefault(db, accountId: "a@x.com", email: "alias@x.com",
                                          use: .newMessage, choice: .signature(alias.id!))
            try SignatureStore.delete(db, id: alias.id!)
        }
        let book = try q.read { try SignatureStore.load($0) }
        // The alias does not start following the primary's signature.
        XCTAssertEqual(book.choice(use: .newMessage, accountId: "a@x.com", email: "alias@x.com"),
                       .none)
        XCTAssertNil(book.defaultSignature(use: .newMessage, accountId: "a@x.com",
                                           email: "alias@x.com"))
        XCTAssertEqual(book.defaultSignature(use: .newMessage, accountId: "a@x.com",
                                             email: "a@x.com")?.body, "Primary")
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

    func testSavedTextIsNormalisedIntoOneBlock() throws {
        let clean = try SignatureStore.normalized(name: "  Work\n",
                                                  body: "-- \r\nAnn\r\n-- \r\nUni\n\n")
        XCTAssertEqual(clean.name, "Work")
        // The leading delimiter goes (MishMail adds its own); one inside
        // would split the block, so it becomes a dash.
        XCTAssertEqual(clean.body, "Ann\n—\nUni")
        XCTAssertEqual(try SignatureStore.normalized(name: " ", body: "x").name, "Signature")
    }

    func testEmptyTooLongOrQuoteLikeSignaturesAreRefusedNotCut() throws {
        for body in [" \n-- \n ", String(repeating: "a", count: SignatureStore.maxBodyLength + 1),
                     "Ann\nOn Mon, Jan 5, 2026 at 9:00 AM, Bob <b@x.com> wrote:\nUni",
                     "Ann\n" + ForwardComposer.marker] {
            XCTAssertThrowsError(try SignatureStore.normalized(name: "n", body: body)) { error in
                XCTAssertTrue(error is SignatureStore.InvalidSignature)
            }
        }
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            XCTAssertThrowsError(try SignatureStore.insert(db, accountId: "a@x.com", name: "n",
                                                           body: "   "))
        }
        XCTAssertEqual(try q.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM signature") }, 0)
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

    /// The automatic rule for a sender of account `account`.
    @discardableResult
    private func apply(_ state: inout ComposeSignatureState, _ signature: SignatureRecord?,
                       to head: String, account: String = "a@x.com") -> String? {
        if case .replaced(let next) = state.senderChanged(to: signature, accountId: account,
                                                         head: head) {
            return next
        }
        return nil
    }

    func testNewMessageGetsTheDefaultBelowAnEmptyBody() {
        var state = ComposeSignatureState()
        XCTAssertEqual(apply(&state, signature(1, "Ann\n**Uni**"), to: ""), "\n\n-- \nAnn\n**Uni**")
        XCTAssertEqual(state.signatureId, 1)
        XCTAssertEqual(state.accountId, "a@x.com")
    }

    func testFromChangeSwapsAnUntouchedSignature() throws {
        var state = ComposeSignatureState()
        let first = try XCTUnwrap(apply(&state, signature(1, "Ann"), to: ""))
        let typed = "Hello" + first
        XCTAssertEqual(apply(&state, signature(2, "Bob", account: "b@x.com"), to: typed,
                             account: "b@x.com"), "Hello\n\n-- \nBob")
        XCTAssertEqual(state.signatureId, 2)
        // To a sender with no default: removed, the user's text kept.
        XCTAssertEqual(apply(&state, nil, to: "Hello\n\n-- \nBob"), "Hello")
        XCTAssertNil(state.block)
        // And back.
        XCTAssertEqual(apply(&state, signature(1, "Ann"), to: "Hello"), "Hello\n\n-- \nAnn")
    }

    func testAliasChangeLeavesAnEditedSignatureAlone() throws {
        var state = ComposeSignatureState()
        let first = try XCTUnwrap(apply(&state, signature(1, "Ann"), to: ""))
        let edited = "Hi" + first + " (mobile)"
        XCTAssertEqual(state.senderChanged(to: signature(2, "Bob"), accountId: "a@x.com",
                                           head: edited), .unchanged)
        XCTAssertEqual(state.senderChanged(to: signature(2, "Bob"), accountId: "A@x.com",
                                           head: "Hi\n\n-- \nAnnie"), .unchanged)
        // Removed by the user: not put back.
        XCTAssertEqual(state.senderChanged(to: signature(2, "Bob"), accountId: "a@x.com",
                                           head: "Hi"), .unchanged)
    }

    func testAnotherAccountOverAnEditedSignatureAsksAndResolves() throws {
        var state = ComposeSignatureState()
        let first = try XCTUnwrap(apply(&state, signature(1, "Ann"), to: ""))
        let edited = "Hi" + first + " (mobile)"
        let bob = signature(2, "Bob", account: "b@x.com")
        XCTAssertEqual(state.senderChanged(to: bob, accountId: "b@x.com", head: edited),
                       .needsDecision)
        // Body untouched until the user answers.
        var replacing = state
        XCTAssertEqual(replacing.resolveReplacing(with: bob, accountId: "b@x.com", head: edited),
                       "Hi\n\n-- \nBob")
        XCTAssertEqual(replacing.signatureId, 2)
        var removing = state
        XCTAssertEqual(removing.resolveReplacing(with: nil, accountId: "b@x.com", head: edited), "Hi")
        // Keep: not asked again for that account.
        var keeping = state
        keeping.resolveKeeping(accountId: "b@x.com")
        XCTAssertEqual(keeping.senderChanged(to: bob, accountId: "b@x.com", head: edited),
                       .unchanged)
    }

    func testAnotherAccountOverATypedSignatureAsksToo() {
        var state = ComposeSignatureState(accountId: "a@x.com")
        XCTAssertEqual(state.senderChanged(to: nil, accountId: "b@x.com", head: "Hi\n\n-- \nmine"),
                       .needsDecision)
    }

    func testASignatureTheUserTypedIsLeftAloneWithinTheAccount() {
        var state = ComposeSignatureState()
        XCTAssertNil(apply(&state, signature(1, "Ann"), to: "Hi\n\n-- \nmy own"))
        // Gmail trimmed the delimiter's space: still a signature, so no
        // second one is appended under it.
        XCTAssertNil(apply(&state, signature(1, "Ann"), to: "Hi\n\n--\nmy own"))
    }

    func testManualChoiceNeverCutsTextMishMailDidNotInsert() throws {
        var state = ComposeSignatureState()
        let first = try XCTUnwrap(apply(&state, signature(1, "Ann"), to: ""))
        // A P.S. typed under the signature stays.
        XCTAssertEqual(state.choose(signature(2, "Bob"), in: "Hi" + first + "\nP.S. call me",
                                    known: ["Ann", "Bob"]),
                       "Hi\n\n-- \nBob\nP.S. call me")
        // An edited signature is not cut: the choice is added at the end.
        var edited = ComposeSignatureState()
        let block = try XCTUnwrap(apply(&edited, signature(1, "Ann"), to: ""))
        XCTAssertEqual(edited.choose(signature(2, "Bob"), in: "Hi" + block + "ie", known: ["Ann", "Bob"]),
                       "Hi\n\n-- \nAnnie\n\n-- \nBob")
        // Pasted text with a delimiter line, and no signature current.
        var none = ComposeSignatureState()
        let pasted = "Fwd text\n-- \nsomeone's footer"
        XCTAssertEqual(none.choose(signature(1, "Ann"), in: pasted, known: ["someone's footer"]),
                       pasted + "\n\n-- \nAnn")
        XCTAssertEqual(none.choose(nil, in: pasted + "\n\n-- \nAnn", known: []), pasted)
    }

    func testNoSignatureRemovesOnlyTheBlock() throws {
        var state = ComposeSignatureState()
        let first = try XCTUnwrap(apply(&state, signature(1, "Ann"), to: ""))
        XCTAssertEqual(state.choose(nil, in: "Dear Bob,\n\nSee you." + first), "Dear Bob,\n\nSee you.")
        XCTAssertNil(state.block)
        XCTAssertNil(state.signatureId)
    }

    func testMenuSelectionFollowsTheBody() throws {
        var state = ComposeSignatureState()
        let first = try XCTUnwrap(apply(&state, signature(1, "Ann"), to: ""))
        XCTAssertEqual(state.selection(in: "Hi" + first), .signature(1))
        XCTAssertEqual(state.selection(in: "Hi"), .none)
        XCTAssertEqual(state.selection(in: "Hi" + first + "!"), .custom)
    }

    func testADraftOpenedAgainKeepsItsBodyAndKnowsItsSignature() {
        let saved = "Hello\n\n-- \nAnn\n"
        let state = ComposeSignatureState.restored(
            head: saved, among: [signature(1, "Ann"), signature(2, "Bob")], accountId: "a@x.com")
        XCTAssertEqual(state.signatureId, 1)
        XCTAssertEqual(state.block, "\n\n-- \nAnn")
        // Its signature swaps like one just inserted once the user picks
        // another sender.
        var next = state
        XCTAssertEqual(apply(&next, signature(2, "Bob"), to: saved), "Hello\n\n-- \nBob")
        // Unknown signature text: the user's own.
        XCTAssertNil(ComposeSignatureState.restored(head: "Hi\n\n-- \nMine",
                                                    among: [signature(1, "Ann")],
                                                    accountId: "a@x.com").block)
    }

    func testADraftBackFromGmailWithoutTheDelimiterSpaceIsRecognised() {
        let state = ComposeSignatureState.restored(head: "Hello\n\n--\nAnn",
                                                   among: [signature(1, "Ann")], accountId: "a@x.com")
        XCTAssertEqual(state.block, "\n\n--\nAnn")
        var next = state
        XCTAssertEqual(apply(&next, signature(2, "Bob"), to: "Hello\n\n--\nAnn"),
                       "Hello\n\n-- \nBob")
    }

    func testAReopenedForwardDraftUsesTheReplyDefault() {
        XCTAssertEqual(SignatureUse.forDraft(referencesHeader: "", body: "Hi"), .newMessage)
        XCTAssertEqual(SignatureUse.forDraft(referencesHeader: "<m@x>", body: "Hi"), .reply)
        XCTAssertEqual(SignatureUse.forDraft(
            referencesHeader: "", body: "FYI\n\n\(ForwardComposer.marker)\nFrom: a"), .reply)
    }

    func testUntouchedReplyStaysUntouchedAcrossQuoteExpandAndCollapse() {
        let head = "\n\n-- \nAnn"          // the automatic signature, nothing typed
        let quote = "On Mon, Bob <b@x.com> wrote:\n> hi"
        let expanded = head + "\n\n" + quote
        let afterExpand = ComposePrefillBaseline.afterExpand(
            head: head, initial: head, quotedTail: quote, expanded: expanded)
        XCTAssertTrue(ComposePrefillBaseline.isUntouched(body: expanded, initial: afterExpand))
        let afterCollapse = ComposePrefillBaseline.afterCollapse(
            body: expanded, initial: afterExpand, head: head)
        XCTAssertTrue(ComposePrefillBaseline.isUntouched(body: head, initial: afterCollapse))
        // Typed text still counts as content.
        XCTAssertFalse(ComposePrefillBaseline.isUntouched(body: "Hi" + head, initial: afterCollapse))
    }

    func testSaveAsSnippetKeepsOnlyTheAuthoredText() {
        XCTAssertEqual(ComposeSignature.authoredText(ofHead: "Thanks!\n\n-- \nAnn"), "Thanks!")
        XCTAssertEqual(ComposeSignature.authoredText(ofHead: "Thanks!"), "Thanks!")
    }

    @MainActor
    func testSignatureSwapIsOneUndoStep() throws {
        let undo = UndoManager()
        final class Delegate: NSObject, NSTextViewDelegate {
            let undo: UndoManager
            init(_ undo: UndoManager) { self.undo = undo }
            func undoManager(for view: NSTextView) -> UndoManager? { undo }
        }
        let delegate = Delegate(undo)
        let textView = NSTextView()
        textView.allowsUndo = true
        textView.delegate = delegate
        textView.string = "Hi\n\n-- \nAnn"
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        XCTAssertTrue(UndoableTextEdit.replace(in: textView, with: "Hi\n\n-- \nBob",
                                               actionName: "Signature"))
        undo.endUndoGrouping()
        XCTAssertEqual(textView.string, "Hi\n\n-- \nBob")
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(textView.string, "Hi\n\n-- \nAnn")
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

    func testImportStripsBidiZeroWidthAndControlCharacters() {
        let result = SignatureImport.markdown(fromGmailHTML:
            "A\u{202E}nn\u{200B} L&#x2066;ee\u{0007}<br>U\u{FEFF}ni")
        XCTAssertEqual(result.body, "Ann Lee\nUni")
    }

    func testImportShowsALinkWhoseLabelNamesAnotherAddress() {
        let result = SignatureImport.markdown(fromGmailHTML:
            "<a href=\"https://evil.example/login\">www.uniba.it</a> <a href=\"https://www.uniba.it/x\">uniba.it</a>")
        XCTAssertEqual(result.body, "www.uniba.it (https://evil.example/login) [uniba.it](https://www.uniba.it/x)")
        XCTAssertEqual(result.droppedLinks, 1)
    }

    func testImportKeepsTableCellsApart() {
        let result = SignatureImport.markdown(fromGmailHTML: """
            <table><tr><td><img src="https://x.example/logo.png"></td><td><b>Ann</b></td>            <td>Uni</td></tr><tr><th>Phone</th><td>123</td></tr></table>
            """)
        XCTAssertEqual(result.body, "**Ann** Uni\nPhone 123")
        XCTAssertEqual(result.droppedImages, 1)
    }

    func testImportGivesOneLineBreakPerBlock() {
        XCTAssertEqual(SignatureImport.markdown(fromGmailHTML:
            "<div>Ann</div><div>Uni</div><div><br></div><div>Bari</div>").body,
                       "Ann\nUni\n\nBari")
    }

    func testImportRefusesOversizedInput() {
        let result = SignatureImport.markdown(fromGmailHTML:
            String(repeating: "<b>a</b>", count: SignatureImport.maxInputLength / 8 + 1))
        XCTAssertTrue(result.tooLarge)
        XCTAssertEqual(result.body, "")
    }

    func testImportCountsRefusedLinksAndDecodesEntitiesOnce() {
        let result = SignatureImport.markdown(fromGmailHTML: """
            <a href="ftp://x.example/f">files</a><BR>            <a href="https://x.example/?a=1&amp;amp;b">A &amp;lt; B</a>
            """)
        XCTAssertEqual(result.body, "files\n[A &lt; B](https://x.example/?a=1&amp;b)")
        XCTAssertEqual(result.droppedLinks, 1)
    }
}

/// v63 (this branch) registers before v64 (per-account notification
/// details, merged first). A database that already ran v64 from `main` must
/// still get v63.
final class SignatureMigrationOrderTests: XCTestCase {
    func testV63RunsOnADatabaseThatAlreadyHasV64() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        // Make it the database of a build without v63: v64 applied, v63 not.
        try q.write { db in
            try db.drop(table: "signatureDefault")
            try db.drop(table: "signature")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v63'")
        }
        try q.read { db in
            let applied = try AppDatabase.migrator.appliedIdentifiers(db)
            XCTAssertTrue(applied.contains("v64"))
            XCTAssertFalse(applied.contains("v63"))
            XCTAssertFalse(try db.tableExists("signature"))
        }
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            XCTAssertTrue(try AppDatabase.migrator.appliedIdentifiers(db).contains("v63"))
            XCTAssertTrue(try db.tableExists("signature"))
            XCTAssertTrue(try db.tableExists("signatureDefault"))
            XCTAssertTrue(try AppDatabase.migrator.hasCompletedMigrations(db))
        }
    }
}
