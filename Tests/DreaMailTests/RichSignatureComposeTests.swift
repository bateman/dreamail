import XCTest
import GRDB

/// A Gmail signature in compose is shown once, rendered, outside the editor
/// text (`ComposeSignatureState.richSignatureId`); the send path gets its
/// text block at the end of the authored head and swaps it for its HTML by
/// that explicit state (`ComposeSignatureStyle`), not by a text match.
final class RichSignatureComposeTests: XCTestCase {
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
        let signature = try XCTUnwrap(try q.read { try SignatureStore.load($0) }.signatures(for: a).first)
        XCTAssertNotNil(ComposeSignature.richHTML(of: signature))
        return signature
    }

    /// A signature made in DreaMail: text only.
    private func plainSignature(_ id: Int64 = 90, _ body: String = "Ann · Example Lab") -> SignatureRecord {
        SignatureRecord(id: id, accountId: a, name: "Short", body: body,
                        createdAt: Date(timeIntervalSince1970: 0))
    }

    /// A message DreaMail sent earlier, ending with the same signature.
    private func earlierMessage(signature: SignatureRecord) -> Message {
        let text = "Earlier\n\n-- \n" + signature.body
        return Message(id: "\(a):m1", accountId: a, gmailId: "m1", threadId: "\(a):t1",
                       fromHeader: "Ann <\(a)>", toHeader: "bob@example.com", ccHeader: "",
                       subject: "Plan", date: Date(timeIntervalSince1970: 1_800_000_000),
                       snippet: "", bodyText: text, bodyHTML: ComposeQuote.authoredHeadHTML(text),
                       messageIdHeader: "<m1@example.com>", referencesHeader: "",
                       labelIds: "INBOX", isUnread: false, hasAttachment: false)
    }

    private func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private let look = "border-right:3px solid #6aa84f"

    /// Gmail's look once, in the authored head only; the plain alternative
    /// carries the signature text once before any quote.
    private func assertOnce(html: String?, text body: String, signature: SignatureRecord,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let html = try XCTUnwrap(html, file: file, line: line).lowercased()
        XCTAssertEqual(count(look, in: html), 1, "the look once", file: file, line: line)
        let quote = html.range(of: "<div class=\"gmail_quote")?.lowerBound ?? html.endIndex
        XCTAssertTrue(html[..<quote].contains(look), "the look before the quote", file: file, line: line)
        XCTAssertFalse(html.contains(ComposeSignature.styleAttribute), "no draft marker in a send",
                       file: file, line: line)
        let head = String(body[..<(ComposeQuote.quoteStart(in: body) ?? body.endIndex)])
        XCTAssertEqual(count(ComposeSignature.normalizedBody(signature.body), in: head), 1,
                       "the text/plain signature once, in the head", file: file, line: line)
    }

    // MARK: - Compose state

    func testARichDefaultIsShownAndLeavesTheEditorEmpty() throws {
        let rich = try gmailCopy()
        var state = ComposeSignatureState()
        XCTAssertEqual(state.senderChanged(to: rich, accountId: a, head: ""), .unchanged)
        XCTAssertEqual(state.richSignatureId, rich.id)
        XCTAssertNil(state.block)
        XCTAssertEqual(state.selection(in: ""), .signature(try XCTUnwrap(rich.id)))
        XCTAssertEqual(state.style, .rich(try XCTUnwrap(rich.id)))
        // A text signature typed by the user stays alone: no block added.
        var typed = ComposeSignatureState()
        XCTAssertEqual(typed.senderChanged(to: rich, accountId: a, head: "Hi\n\n-- \nmine"), .unchanged)
        XCTAssertNil(typed.richSignatureId)
    }

    func testChoosingSwapsTextAndRenderedSignatures() throws {
        let rich = try gmailCopy(), short = plainSignature()
        var state = ComposeSignatureState()
        var head = state.choose(short, in: "Hello", known: [short.body, rich.body])
        XCTAssertEqual(head, "Hello\n\n-- \n" + short.body)
        XCTAssertNil(state.richSignatureId)
        // Rich: the text block goes, the rendered one comes.
        head = state.choose(rich, in: head, known: [short.body, rich.body])
        XCTAssertEqual(head, "Hello")
        XCTAssertEqual(state.richSignatureId, rich.id)
        XCTAssertEqual(ComposeSignatureMenu.rows(signatures: [rich, short],
                                                 selection: state.selection(in: head),
                                                 richShown: true).suffix(2),
                       [.divider, .editAsText])
        // Back to text.
        head = state.choose(short, in: head, known: [short.body, rich.body])
        XCTAssertEqual(head, "Hello\n\n-- \n" + short.body)
        XCTAssertNil(state.richSignatureId)
        XCTAssertFalse(ComposeSignatureMenu.rows(signatures: [rich, short],
                                                 selection: state.selection(in: head))
            .contains(.editAsText))
        // No signature removes a rendered one; the text stays as typed.
        head = state.choose(rich, in: head, known: [short.body, rich.body])
        head = state.choose(nil, in: head, known: [short.body, rich.body])
        XCTAssertEqual(head, "Hello")
        XCTAssertNil(state.richSignatureId)
        XCTAssertEqual(state.selection(in: head), .none)
    }

    func testEditAsTextPutsTheTextInTheEditorAndSendsItAsTyped() throws {
        let rich = try gmailCopy()
        var state = ComposeSignatureState()
        _ = state.choose(rich, in: "Hello Bob", known: [rich.body])
        let head = try XCTUnwrap(state.editAsText(rich, in: "Hello Bob"))
        XCTAssertEqual(head, "Hello Bob\n\n-- \n" + ComposeSignature.normalizedBody(rich.body))
        XCTAssertNil(state.richSignatureId)
        XCTAssertEqual(state.style, .plain)
        XCTAssertEqual(state.selection(in: head), .signature(try XCTUnwrap(rich.id)))
        // Not a second time.
        XCTAssertNil(state.editAsText(rich, in: head))
        // Unedited, it still goes out as the text the user sees.
        let html = try XCTUnwrap(OutgoingHTML.build(body: head, forwardOf: nil, replyTo: nil,
                                                    draft: nil, threadMessages: [],
                                                    signatures: [rich], style: state.style))
        XCTAssertFalse(html.lowercased().contains(look))
        XCTAssertTrue(html.contains(ComposeQuote.signatureBlockHTML(
            ComposeSignature.normalizedBody(rich.body))))
    }

    func testAFromChangeFollowsTheDefaultWithARenderedSignature() throws {
        let rich = try gmailCopy(), short = plainSignature()
        var state = ComposeSignatureState()
        _ = state.senderChanged(to: rich, accountId: a, head: "Hi")
        // To a text default: its block is added.
        XCTAssertEqual(state.senderChanged(to: short, accountId: a, head: "Hi"),
                       .replaced("Hi\n\n-- \n" + short.body))
        XCTAssertNil(state.richSignatureId)
        // Back to the rich one: the text block goes.
        XCTAssertEqual(state.senderChanged(to: rich, accountId: a, head: "Hi\n\n-- \n" + short.body),
                       .replaced("Hi"))
        XCTAssertEqual(state.richSignatureId, rich.id)
        // To none.
        XCTAssertEqual(state.senderChanged(to: nil, accountId: "b@example.com", head: "Hi"), .unchanged)
        XCTAssertNil(state.richSignatureId)
        XCTAssertNil(state.signatureId)
    }

    // MARK: - Assembly

    func testANewMessageCarriesTheSignatureOnceInEachPart() throws {
        let rich = try gmailCopy()
        let body = ComposeSignature.assembled(body: "Hello Bob\n", signature: rich)
        XCTAssertEqual(body, "Hello Bob\n\n-- \n" + ComposeSignature.normalizedBody(rich.body))
        let html = OutgoingHTML.build(body: body, forwardOf: nil, replyTo: nil, draft: nil,
                                      threadMessages: [], signatures: [rich],
                                      style: .rich(try XCTUnwrap(rich.id)))
        try assertOnce(html: html, text: body, signature: rich)
        XCTAssertTrue(try XCTUnwrap(html).contains("Hello Bob"))
    }

    func testAReplyCarriesItBeforeTheQuoteNeverInIt() throws {
        let rich = try gmailCopy()
        let original = earlierMessage(signature: rich)
        // The editor as compose holds it: the text, then the collapsed quote.
        let full = "Thanks" + "\n\n" + ReplyComposer.plainQuote(of: original)
        let body = ComposeSignature.assembled(body: full, signature: rich)
        let html = OutgoingHTML.build(body: body, forwardOf: nil, replyTo: original, draft: nil,
                                      threadMessages: [], signatures: [rich],
                                      style: .rich(try XCTUnwrap(rich.id)))
        try assertOnce(html: html, text: body, signature: rich)
        let unwrapped = try XCTUnwrap(html)
        let quote = try XCTUnwrap(unwrapped.range(of: "<div class=\"gmail_quote"))
        XCTAssertTrue(unwrapped[quote.lowerBound...].contains(ComposeQuote.signatureBlockHTML(rich.body)),
                      "the quoted message keeps its own plain block")
        // The quote is still the untouched one, so the reply keeps its HTML upgrade.
        XCTAssertNotNil(ReplyComposer.matchHTMLUpgrade(body: body, original: original))
    }

    func testAForwardCarriesItBeforeTheForwardedMessage() throws {
        let rich = try gmailCopy()
        let original = earlierMessage(signature: rich)
        let full = "FYI\n\n" + ForwardComposer.forwardBlock(parts: [ForwardComposer.Part(message: original)])
        let body = ComposeSignature.assembled(body: full, signature: rich)
        let html = OutgoingHTML.build(body: body, forwardOf: original, replyTo: nil, draft: nil,
                                      threadMessages: [original], signatures: [rich],
                                      style: .rich(try XCTUnwrap(rich.id)))
        try assertOnce(html: html, text: body, signature: rich)
        XCTAssertNotNil(ForwardComposer.matchHTMLUpgrade(body: body, original: original,
                                                         threadMessages: [original]))
    }

    func testAPlainSignatureIsUnchanged() throws {
        let short = plainSignature()
        var state = ComposeSignatureState()
        let head = state.choose(short, in: "Hello", known: [short.body])
        XCTAssertEqual(head, "Hello\n\n-- \n" + short.body)
        XCTAssertNil(state.richSignatureId)
        XCTAssertNil(ComposeSignature.richId(of: short))
        let html = try XCTUnwrap(OutgoingHTML.build(body: head, forwardOf: nil, replyTo: nil,
                                                    draft: nil, threadMessages: [],
                                                    signatures: [short], style: state.style))
        XCTAssertEqual(html, ComposeQuote.authoredHeadHTML(head))
        XCTAssertEqual(count("gmail_signature\"", in: html), 2, "one block (class and data-smartmail)")
    }

    // MARK: - Drafts opened again

    func testANewStyleDraftOpensWithTheRenderedSignatureAndNoCopy() throws {
        let rich = try gmailCopy()
        let id = try XCTUnwrap(rich.id)
        let original = earlierMessage(signature: rich)
        let full = "Thanks" + "\n\n" + ReplyComposer.plainQuote(of: original)
        let body = ComposeSignature.assembled(body: full, signature: rich)
        let saved = try XCTUnwrap(OutgoingHTML.build(body: body, forwardOf: nil, replyTo: original,
                                                     draft: nil, threadMessages: [],
                                                     signatures: [rich], style: .rich(id),
                                                     marksDraft: true))
        XCTAssertEqual(ComposeSignature.markedStyle(in: saved), .rich(id))
        XCTAssertEqual(count(ComposeSignature.styleAttribute, in: saved), 1)
        // Opened again: Gmail's text part is the body; the head loses the text block.
        let head = String(body[..<(ComposeQuote.quoteStart(in: body) ?? body.endIndex)])
        let restored = ComposeSignatureState.restored(head: head, among: [rich], accountId: a,
                                                      style: .rich(id))
        XCTAssertEqual(restored.state.richSignatureId, id)
        XCTAssertNil(restored.state.block)
        XCTAssertEqual(restored.head, "Thanks")
        // Assembled again it is the same body: no second signature.
        let reopened = restored.head + String(body[head.endIndex...])
        XCTAssertEqual(ComposeSignature.assembled(body: reopened, signature: rich), body)
        // Sent from the reopened draft: rebuilt, the look once, no marker.
        var draft = original
        draft.bodyText = body
        draft.bodyHTML = saved
        let sent = OutgoingHTML.build(body: body, forwardOf: nil, replyTo: original, draft: draft,
                                      threadMessages: [], signatures: [rich], style: .rich(id))
        try assertOnce(html: sent, text: body, signature: rich)
    }

    func testAMarkedDraftIsNotReusedForAnotherStyle() throws {
        let rich = try gmailCopy()
        let id = try XCTUnwrap(rich.id)
        let body = ComposeSignature.assembled(body: "Hello", signature: rich)
        let saved = try XCTUnwrap(OutgoingHTML.build(body: body, forwardOf: nil, replyTo: nil,
                                                     draft: nil, threadMessages: [],
                                                     signatures: [rich], style: .rich(id),
                                                     marksDraft: true))
        var draft = earlierMessage(signature: rich)
        draft.bodyText = body
        draft.bodyHTML = saved
        // "Edit signature as text" left the same text: it goes out as text.
        let html = try XCTUnwrap(OutgoingHTML.build(body: body, forwardOf: nil, replyTo: nil,
                                                    draft: draft, threadMessages: [],
                                                    signatures: [rich], style: .plain))
        XCTAssertFalse(html.lowercased().contains(look))
        XCTAssertFalse(html.contains(ComposeSignature.styleAttribute))
        // Saved as text, it opens as text.
        let savedPlain = try XCTUnwrap(OutgoingHTML.build(body: body, forwardOf: nil, replyTo: nil,
                                                          draft: nil, threadMessages: [],
                                                          signatures: [rich], style: .plain,
                                                          marksDraft: true))
        XCTAssertEqual(ComposeSignature.markedStyle(in: savedPlain), .plain)
        let restored = ComposeSignatureState.restored(head: body, among: [rich], accountId: a,
                                                      style: .plain)
        XCTAssertEqual(restored.head, body)
        XCTAssertNil(restored.state.richSignatureId)
        XCTAssertFalse(restored.state.legacy)
        XCTAssertEqual(restored.state.signatureId, id)
    }

    func testADraftFromTheEarlierBuildStaysText() throws {
        let rich = try gmailCopy()
        let body = "Hello\n\n-- \n" + rich.body
        // Saved before this change: no style on its signature block.
        let old = ComposeQuote.authoredHeadHTML(body)
        XCTAssertNil(ComposeSignature.markedStyle(in: old))
        let restored = ComposeSignatureState.restored(head: body, among: [rich], accountId: a,
                                                      style: .legacy)
        XCTAssertEqual(restored.head, body, "the text stays in the editor")
        XCTAssertNil(restored.state.richSignatureId)
        XCTAssertEqual(restored.state.style, .legacy)
        XCTAssertEqual(restored.state.signatureId, rich.id)
        // #79's rule still applies to it: unedited, Gmail's look, once.
        let html = OutgoingHTML.build(body: body, forwardOf: nil, replyTo: nil, draft: nil,
                                      threadMessages: [], signatures: [rich], style: .legacy)
        try assertOnce(html: html, text: body, signature: rich)
    }

    func testARichStyleWhoseTextWasEditedStaysText() throws {
        let rich = try gmailCopy()
        let id = try XCTUnwrap(rich.id)
        let edited = ComposeSignature.assembled(body: "Hello", signature: rich) + " (on leave)"
        let restored = ComposeSignatureState.restored(head: edited, among: [rich], accountId: a,
                                                      style: .rich(id))
        XCTAssertEqual(restored.head, edited)
        XCTAssertNil(restored.state.richSignatureId)
        // And the explicit swap never replaces other text.
        let html = ComposeQuote.authoredHeadHTML(edited)
        XCTAssertEqual(ComposeSignature.withRichSignature(html, head: edited, signature: rich), html)
    }

    func testAMarkerInsideAQuoteIsIgnored() throws {
        let quoted = "<div>Hi</div><div class=\"gmail_quote\">"
            + "<div class=\"gmail_signature\" data-smartmail=\"gmail_signature\" "
            + "\(ComposeSignature.styleAttribute)=\"rich:1\">x</div></div>"
        XCTAssertNil(ComposeSignature.markedStyle(in: quoted))
    }

    // MARK: - Review round 1

    /// R1: a reopened forward draft has no original to rebuild from: its own
    /// HTML (same style) is reused, the look once, the forwarded HTML kept,
    /// no marker on the send. Through `OutgoingHTML.build` (no test goes
    /// through `MailStore.send`).
    func testAReopenedForwardDraftKeepsTheLookAndTheForwardedHTML() throws {
        let rich = try gmailCopy()
        let id = try XCTUnwrap(rich.id)
        var original = earlierMessage(signature: rich)
        original.bodyHTML = "<div style=\"color:#336699\">Earlier, formatted</div>"
        let full = "FYI\n\n" + ForwardComposer.forwardBlock(parts: [ForwardComposer.Part(message: original)])
        let body = ComposeSignature.assembled(body: full, signature: rich)
        for style in [ComposeSignatureStyle.rich(id), .plain] {
            let saved = try XCTUnwrap(OutgoingHTML.build(body: body, forwardOf: original, replyTo: nil,
                                                         draft: nil, threadMessages: [original],
                                                         signatures: [rich], style: style,
                                                         marksDraft: true))
            XCTAssertTrue(saved.contains("color:#336699"))
            var draft = original
            draft.bodyText = body
            draft.bodyHTML = saved
            let sent = try XCTUnwrap(OutgoingHTML.build(body: body, forwardOf: nil, replyTo: nil,
                                                        draft: draft, threadMessages: [],
                                                        signatures: [rich], style: style))
            XCTAssertTrue(sent.contains("color:#336699"), "the forwarded HTML is kept")
            XCTAssertFalse(sent.contains(ComposeSignature.styleAttribute))
            if style == .rich(id) {
                try assertOnce(html: sent, text: body, signature: rich)
            } else {
                XCTAssertFalse(sent.lowercased().contains(look))
            }
            // Saved again: marked once, afresh.
            let resaved = try XCTUnwrap(OutgoingHTML.build(body: body, forwardOf: nil, replyTo: nil,
                                                           draft: draft, threadMessages: [],
                                                           signatures: [rich], style: style,
                                                           marksDraft: true))
            XCTAssertEqual(count(ComposeSignature.styleAttribute, in: resaved), 1)
            XCTAssertEqual(ComposeSignature.markedStyle(in: resaved), style)
        }
    }

    /// R2: an editor that re-saved the draft may move the attribute or change
    /// its quotes; it is still read, and a send never carries it, wherever it is.
    func testTheMarkerIsReadTolerantlyAndNeverSent() throws {
        let reordered = "<div data-dreamail-signature='rich:5' dir=\"ltr\" class=\"gmail_signature\">"
            + "-- <br>Ann</div>"
        XCTAssertEqual(ComposeSignature.markedStyle(in: reordered), .rich(5))
        XCTAssertEqual(ComposeSignature.markedStyle(in: "<div DATA-DREAMAIL-SIGNATURE = plain>x</div>"), .plain)
        let everywhere = "<div x=\"1\" data-dreamail-signature=\"plain\">a</div>"
            + "<div class=\"gmail_quote\"><span data-dreamail-signature='rich:9'>b</span>"
            + "<p data-dreamail-signature=rich:3>c</p></div>"
        let quotePart = "<div class=\"gmail_quote\"><span data-dreamail-signature='rich:9'>b</span>"
            + "<p data-dreamail-signature=rich:3>c</p></div>"
        let stripped = ComposeSignature.strippingStyle(everywhere)
        // The head's tags lose it; the quoted part stays byte for byte.
        XCTAssertEqual(stripped, "<div x=\"1\">a</div>" + quotePart)
        // A draft reused verbatim on send loses it too.
        var draft = try earlierMessage(signature: gmailCopy())
        draft.bodyText = "Hello"
        draft.bodyHTML = everywhere
        let sent = try XCTUnwrap(OutgoingHTML.build(body: "Hello", forwardOf: nil, replyTo: nil,
                                                    draft: draft, threadMessages: [],
                                                    signatures: [], style: .plain))
        XCTAssertEqual(sent, "<div x=\"1\">a</div>" + quotePart)
        // Linear on a long run of white space.
        let start = Date()
        _ = ComposeSignature.strippingStyle("data-dreamail-signature" + String(repeating: " ", count: 200_000) + "x")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// Round 2, F1: the real reopen flow. Saved, opened again (the text
    /// block cut from the head, what follows it kept), joined with the
    /// quote and assembled: the saved body byte for byte, so the draft's own
    /// HTML is reused and a forward keeps the look and its forwarded HTML.
    func testAReopenedForwardRoundTripsByteForByte() throws {
        let rich = try gmailCopy()
        let id = try XCTUnwrap(rich.id)
        var original = earlierMessage(signature: rich)
        original.bodyHTML = "<div style=\"color:#336699\">Earlier, formatted</div>"
        // As compose holds it: the text, then the collapsed forwarded block.
        let full = "FYI" + "\n\n" + ForwardComposer.forwardBlock(parts: [ForwardComposer.Part(message: original)])
        let saved = ComposeSignature.assembled(body: full, signature: rich)
        let savedHTML = try XCTUnwrap(OutgoingHTML.build(body: saved, forwardOf: original, replyTo: nil,
                                                         draft: nil, threadMessages: [original],
                                                         signatures: [rich], style: .rich(id),
                                                         marksDraft: true))
        // text/plain keeps the blank line before the forwarded block.
        XCTAssertTrue(saved.contains(ComposeSignature.normalizedBody(rich.body) + "\n\n" + ForwardComposer.marker))
        for text in [saved, saved.replacingOccurrences(of: "\n-- \n", with: "\n--\n")] {
            // Opened again (also as Gmail may return it, the space trimmed).
            let quote = try XCTUnwrap(ComposeQuote.quoteStart(in: text))
            let restored = ComposeSignatureState.restored(head: String(text[..<quote]), among: [rich],
                                                          accountId: a, style: .rich(id))
            XCTAssertEqual(restored.state.richSignatureId, id)
            XCTAssertFalse(restored.head.contains("-- "))
            let reopened = restored.head + String(text[quote...])
            let outgoing = ComposeSignature.assembled(body: reopened, signature: rich)
            if text == saved {
                XCTAssertEqual(outgoing, saved, "assembled again: the saved body byte for byte")
            }
            XCTAssertTrue(OutgoingHTML.sameText(outgoing, saved))
            XCTAssertTrue(OutgoingHTML.sameText(outgoing, text))
            var draft = original
            draft.bodyText = text
            draft.bodyHTML = savedHTML
            let sent = try XCTUnwrap(OutgoingHTML.build(body: outgoing, forwardOf: nil, replyTo: nil,
                                                        draft: draft, threadMessages: [],
                                                        signatures: [rich], style: .rich(id)))
            XCTAssertTrue(sent.contains("color:#336699"), "the forwarded HTML is kept")
            try assertOnce(html: sent, text: outgoing, signature: rich)
        }
    }

    /// Round 2, F2: only the head's tags lose the attribute. Typed text that
    /// reads like it, and quoted mail, stay byte for byte; nothing can be
    /// joined into a new tag.
    func testTheStripTouchesOnlyTagsInTheHead() {
        let typed = "<div dir=\"ltr\">please set data-dreamail-signature=plain</div><div>next</div>"
        XCTAssertEqual(ComposeSignature.strippingStyle(typed), typed)
        XCTAssertNil(ComposeSignature.markedStyle(in: typed))
        let joined = "<div>Hi</div><div class=\"gmail_quote\"><scr data-dreamail-signature=\"\"ipt>alert(1)</div>"
        XCTAssertEqual(ComposeSignature.strippingStyle(joined), joined)
        let split = "<div>Hi</div><div class=\"gmail_quote\">"
            + "<a title=\"x data-dreamail-signature='rich:1' y\" href=\"https://example.com\">z</a></div>"
        XCTAssertEqual(ComposeSignature.strippingStyle(split), split)
        let head = "<scr data-dreamail-signature=\"\"ipt>x"
        XCTAssertEqual(ComposeSignature.strippingStyle(head), head)
        // As the head builder writes it: the typed sentence goes out as typed.
        let built = ComposeQuote.authoredHeadHTML("please set data-dreamail-signature=plain\n\n-- \nAnn")
        XCTAssertTrue(built.contains("data-dreamail-signature=plain"), built)
        XCTAssertEqual(ComposeSignature.strippingStyle(built), built)
    }

    /// R3: ⌘Z after choosing the rendered signature puts its text back. The
    /// assembly keeps it once, and the compose state turns back to text.
    func testUndoAfterChoosingTheRenderedSignatureKeepsItOnce() throws {
        let rich = try gmailCopy()
        var state = ComposeSignatureState()
        let typed = state.choose(rich, in: "Hello", known: [rich.body])
        XCTAssertEqual(state.richSignatureId, rich.id)
        // ⌘Z: the editor holds the text again while the state is still rich.
        let undone = ComposeSignature.assembled(body: typed, signature: rich)
        XCTAssertEqual(ComposeSignature.assembled(body: undone, signature: rich), undone)
        let html = OutgoingHTML.build(body: undone, forwardOf: nil, replyTo: nil, draft: nil,
                                      threadMessages: [], signatures: [rich],
                                      style: .rich(try XCTUnwrap(rich.id)))
        try assertOnce(html: html, text: undone, signature: rich)
        // With a quote after it, too.
        let original = earlierMessage(signature: rich)
        let reply = undone + "\n\n" + ReplyComposer.plainQuote(of: original)
        XCTAssertEqual(ComposeSignature.assembled(body: reply, signature: rich), reply)
        // The window follows: text again, no rendered block.
        XCTAssertTrue(state.textReturned(in: undone, signature: rich))
        XCTAssertNil(state.richSignatureId)
        XCTAssertEqual(state.selection(in: undone), .signature(try XCTUnwrap(rich.id)))
        XCTAssertFalse(state.textReturned(in: undone, signature: rich))
        var other = ComposeSignatureState()
        _ = other.choose(rich, in: "Hello", known: [])
        XCTAssertFalse(other.textReturned(in: "Hello", signature: rich))
    }

    // MARK: - Stored style

    func testTheStyleRoundTripsThroughStorage() {
        for style in [ComposeSignatureStyle.legacy, .plain, .rich(42)] {
            XCTAssertEqual(ComposeSignatureStyle(storageValue: style.storageValue), style)
        }
        XCTAssertEqual(ComposeSignatureStyle(storageValue: "rich:x"), .legacy)
        XCTAssertEqual(ComposeSignatureStyle(storageValue: "rich:-3"), .legacy)
        XCTAssertEqual(ComposeSignatureStyle(storageValue: "other"), .legacy)
    }

    func testV68KeepsTheStyleOfScheduledAndOutboxMessages() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            XCTAssertTrue(try AppDatabase.migrator.appliedIdentifiers(db).contains("v68"))
            try Account(id: self.a, displayName: self.a, historyId: nil, lastSyncAt: nil,
                        senderName: "").insert(db)
            try ScheduledSend(
                id: nil, accountId: self.a, toHeader: "bob@example.com", ccHeader: "", bccHeader: "",
                subject: "Hi", body: "Hello", sendAt: Date(), replyToMessageId: nil, forward: false,
                replacingDraftId: nil, attachmentsJSON: Data("[]".utf8), createdAt: Date(),
                signatureStyle: ComposeSignatureStyle.rich(7).storageValue).insert(db)
            try LocalDraft(
                id: nil, accountId: self.a, fromEmail: "", toHeader: "", ccHeader: "", bccHeader: "",
                subject: "Hi", body: "Hello", replyToMessageId: nil, forward: false,
                replacingDraftId: nil, attachmentsJSON: Data("[]".utf8), createdAt: Date(),
                updatedAt: Date(), signatureStyle: ComposeSignatureStyle.plain.storageValue).insert(db)
        }
        try q.read { db in
            let scheduled = try XCTUnwrap(try ScheduledSend.fetchOne(db))
            XCTAssertEqual(ComposeSignatureStyle(storageValue: scheduled.signatureStyle), .rich(7))
            let local = try XCTUnwrap(try LocalDraft.fetchOne(db))
            XCTAssertEqual(ComposeSignatureStyle(storageValue: local.signatureStyle), .plain)
        }
    }
}
