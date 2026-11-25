import XCTest

final class AskAIToolsTests: XCTestCase {
    func testSpecsIncludeCatalogAndSendDraft() throws {
        let specs = AskAITools.llmToolSpecs()
        let names = specs.map(\.name)
        XCTAssertTrue(names.contains("search_threads"))
        XCTAssertTrue(names.contains("create_draft"))
        XCTAssertTrue(names.contains("send_draft"))
        XCTAssertEqual(names.count, MCPTools.catalog.count + 1)
        // Schemas are valid JSON objects.
        for spec in specs {
            let object = try JSONSerialization.jsonObject(with: Data(spec.inputSchemaJSON.utf8))
            XCTAssertNotNil(object as? [String: Any], spec.name)
        }
    }

    /// send_draft is Ask AI-only: external MCP clients must not see it.
    func testSendDraftIsNotInMCPCatalog() {
        XCTAssertFalse(MCPTools.catalog.map(\.name).contains(AskAITools.sendDraftToolName))
    }

    func testSendDraftSchemaRequiresDraftId() throws {
        let specs = AskAITools.llmToolSpecs()
        guard let spec = specs.first(where: { $0.name == "send_draft" }) else {
            return XCTFail("send_draft missing")
        }
        let object = try JSONSerialization.jsonObject(
            with: Data(spec.inputSchemaJSON.utf8)) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "object")
        XCTAssertEqual(object?["required"] as? [String], ["draft_id"])
        let properties = object?["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["draft_id"])
        XCTAssertFalse(spec.description.isEmpty)
    }

    func testWriteToolClassification() {
        XCTAssertTrue(AskAITools.isWriteTool("create_draft"))
        XCTAssertTrue(AskAITools.isWriteTool("send_draft"))
        XCTAssertTrue(AskAITools.isWriteTool("remove_vip"))
        XCTAssertTrue(AskAITools.isWriteTool("set_thread_summary"))
        XCTAssertTrue(AskAITools.isWriteTool("clear_thread_summary"))
        XCTAssertTrue(AskAITools.isWriteTool("add_vip"))
        XCTAssertTrue(AskAITools.isWriteTool("add_vips"))
        XCTAssertTrue(AskAITools.isWriteTool("set_vip_groups"))
        XCTAssertFalse(AskAITools.isWriteTool("search_threads"))
        XCTAssertFalse(AskAITools.isWriteTool("get_thread"))
        XCTAssertFalse(AskAITools.isWriteTool("list_accounts"))
        XCTAssertFalse(AskAITools.isWriteTool("list_threads"))
        XCTAssertFalse(AskAITools.isWriteTool("list_drafts"))
        XCTAssertFalse(AskAITools.isWriteTool("list_vips"))
        XCTAssertTrue(AskAITools.isWriteTool("invented_mutating_tool"),
                      "unknown tools must confirm, not run as reads")
    }

    /// Every offered tool is classified read or write on purpose — a new
    /// mutating tool must be added to the write set, not default to read.
    func testEveryOfferedToolIsClassified() {
        let names = Set(AskAITools.llmToolSpecs().map(\.name))
        XCTAssertTrue(AskAITools.writeToolNames.isDisjoint(with: AskAITools.readToolNames))
        XCTAssertEqual(names, AskAITools.writeToolNames.union(AskAITools.readToolNames),
                       "A new tool must be added to readToolNames or writeToolNames")
    }

    func testCreateAndSendRequireExplicitClick() {
        XCTAssertTrue(AskAITools.requiresExplicitClick("create_draft"))
        XCTAssertTrue(AskAITools.requiresExplicitClick("send_draft"))
        XCTAssertTrue(AskAITools.requiresExplicitClick("add_vip"))
        XCTAssertTrue(AskAITools.requiresExplicitClick("set_thread_summary"))
        XCTAssertTrue(AskAITools.requiresExplicitClick("invented_mutating_tool"))
        XCTAssertFalse(AskAITools.requiresExplicitClick("search_threads"))
    }

    func testCreateDraftConfirmIncludesBodyPreview() {
        let content = AskAITools.confirmContent(
            toolName: "create_draft",
            argumentsJSON: #"{"account":"a@b.com","to":["c@d.com"],"subject":"Hello","body":"Please send the files."}"#)
        XCTAssertTrue(content.summary.contains("c@d.com"))
        XCTAssertEqual(content.bodyPreview, "Please send the files.")
        XCTAssertTrue(content.requiresExplicitClick)
    }

    func testComposePrefillReadsCreateDraftArguments() {
        let prefill = AskAITools.composePrefill(argumentsJSON: """
            {"account":"a@b.com","to":["c@d.com","e@f.com"],"cc":["g@h.com"],\
            "subject":"Hello","body":"Please send the files."}
            """)
        XCTAssertEqual(prefill?.to, "c@d.com, e@f.com")
        XCTAssertEqual(prefill?.cc, "g@h.com")
        XCTAssertEqual(prefill?.bcc, "")
        XCTAssertEqual(prefill?.subject, "Hello")
        XCTAssertEqual(prefill?.body, "Please send the files.")
        XCTAssertNil(AskAITools.composePrefill(argumentsJSON: #"{"subject":"x"}"#))
    }

    func testSendFingerprintChangesWhenBodyChanges() {
        let a = AskAITools.sendFingerprint(
            accountId: "acct", from: "me@x.com",
            to: "a@b.com", cc: "", bcc: "", subject: "Hi", body: "one")
        let b = AskAITools.sendFingerprint(
            accountId: "acct", from: "me@x.com",
            to: "a@b.com", cc: "", bcc: "", subject: "Hi", body: "two")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, AskAITools.sendFingerprint(
            accountId: "acct", from: "me@x.com",
            to: "a@b.com", cc: "", bcc: "", subject: "Hi", body: "one"))
        let otherFrom = AskAITools.sendFingerprint(
            accountId: "acct", from: "other@x.com",
            to: "a@b.com", cc: "", bcc: "", subject: "Hi", body: "one")
        XCTAssertNotEqual(a, otherFrom)
    }

    func testSendDraftSummaryNamesFrom() {
        let line = AskAITools.sendDraftSummary(
            recipients: ["a@b.com"], subject: "Hi", from: "me@x.com")
        XCTAssertTrue(line.contains("me@x.com"), line)
        XCTAssertTrue(line.contains("a@b.com"), line)
    }

    func testOffThreadRecipientsIgnoresPeopleAlreadyOnTheThread() {
        let off = AskAITools.offThreadRecipients(
            sending: ["Eve@x.com", "a@b.com", "eve@x.com"],
            threadAddresses: ["a@b.com", "c@d.com"])
        XCTAssertEqual(off, ["Eve@x.com"])
    }

    func testPreviewKeepsLongBodiesForFullReview() {
        XCTAssertNil(AskAITools.preview("   "))
        XCTAssertEqual(AskAITools.preview("short"), "short")
        let long = String(repeating: "x", count: 600)
        let preview = AskAITools.preview(long, limit: 500)
        XCTAssertEqual(preview?.count, 600)
        XCTAssertFalse(preview?.hasSuffix("…") == true)
    }

    func testCreateDraftSummaryWarnsAboutBccAndOffThreadRecipients() {
        let summary = AskAITools.createDraftSummary(
            recipients: ["new@example.com"], subject: "Hi", hiddenCount: 1,
            offThreadRecipients: ["new@example.com"])
        XCTAssertTrue(summary.contains("Bcc"))
        XCTAssertTrue(summary.contains("not on the thread"))
    }

    func testCollapsedBlankLinesExposeHiddenBodyContent() {
        let collapsed = AskAITools.collapsedBlankLines("top\n\n\n\nsecret")
        XCTAssertTrue(collapsed.contains("blank lines"))
        XCTAssertTrue(collapsed.contains("secret"))
    }

    func testDecodeArgumentsRejectsNonObject() {
        XCTAssertNoThrow(try AskAITools.decodeArguments(#"{"query":"acme"}"#))
        XCTAssertThrowsError(try AskAITools.decodeArguments(#"["not","object"]"#))
        XCTAssertThrowsError(try AskAITools.decodeArguments("not json"))
        XCTAssertThrowsError(try AskAITools.decodeArguments("42"))
    }

    func testDecodeArgumentsProducesDispatcherValues() throws {
        let args = try AskAITools.decodeArguments(
            #"{"query":"acme","limit":10,"unread_only":true,"to":["a@b.com"]}"#)
        XCTAssertEqual(args["query"], .string("acme"))
        XCTAssertEqual(args["limit"], .int(10))
        XCTAssertEqual(args["unread_only"], .bool(true))
        XCTAssertEqual(args["to"], .array([.string("a@b.com")]))
    }

    /// No-arg tools (list_accounts) arrive with an empty or missing argument
    /// blob from some providers; that means "no arguments", not a parse error.
    func testDecodeArgumentsAcceptsEmptyInput() throws {
        XCTAssertEqual(try AskAITools.decodeArguments(""), [:])
        XCTAssertEqual(try AskAITools.decodeArguments("   "), [:])
        XCTAssertEqual(try AskAITools.decodeArguments("{}"), [:])
    }

    func testConfirmSummaryNamesTheAction() {
        let summary = AskAITools.confirmSummary(
            toolName: "create_draft",
            argumentsJSON: #"{"account":"a@b.com","to":["c@d.com"],"subject":"Hello","body":"x"}"#)
        XCTAssertTrue(summary.contains("c@d.com"))
        XCTAssertTrue(summary.contains("Hello"))
    }

    func testConfirmSummaryCoversEveryWriteTool() {
        let cases: [(String, String, [String])] = [
            ("send_draft", #"{"draft_id":"acct:1234"}"#, ["Send", "acct:1234"]),
            ("set_thread_summary",
             #"{"thread_id":"a:t1","summary":"s","model":"m"}"#, ["a:t1"]),
            ("clear_thread_summary", #"{"thread_id":"a:t1"}"#, ["a:t1"]),
            ("add_vip", #"{"email":"v@x.com"}"#, ["v@x.com"]),
            ("add_vips", #"{"emails":["v@x.com","w@x.com"]}"#, ["v@x.com"]),
            ("set_vip_groups",
             #"{"email":"v@x.com","groups":["Team"]}"#, ["v@x.com", "Team"]),
            ("remove_vip", #"{"email":"v@x.com"}"#, ["v@x.com"]),
        ]
        for (name, json, needles) in cases {
            let summary = AskAITools.confirmSummary(toolName: name, argumentsJSON: json)
            XCTAssertFalse(summary.isEmpty, name)
            for needle in needles {
                XCTAssertTrue(summary.contains(needle), "\(name) missing \(needle): \(summary)")
            }
        }
    }

    /// The resolved send line names the recipients and the subject — the
    /// confirm card is the last barrier before mail leaves.
    func testSendDraftSummaryNamesRecipientsAndSubject() {
        let line = AskAITools.sendDraftSummary(
            recipients: ["a@b.com", "c@d.com"], subject: "Q3 numbers")
        XCTAssertTrue(line.contains("a@b.com"), line)
        XCTAssertTrue(line.contains("c@d.com"), line)
        XCTAssertTrue(line.contains("Q3 numbers"), line)
        XCTAssertFalse(line.contains("draft_id"), line)
    }

    func testSendDraftSummaryHandlesMissingParts() {
        let noSubject = AskAITools.sendDraftSummary(
            recipients: ["a@b.com"], subject: "   ")
        XCTAssertEqual(noSubject, "Send the draft to a@b.com.")
        let noRecipient = AskAITools.sendDraftSummary(recipients: [], subject: "Hi")
        XCTAssertTrue(noRecipient.hasPrefix("Send the draft"), noRecipient)
        XCTAssertTrue(noRecipient.contains("Hi"), noRecipient)
        XCTAssertFalse(
            AskAITools.sendDraftSummary(recipients: [], subject: "").isEmpty)
    }

    /// Bcc recipients are counted on the card, never named.
    func testSendDraftSummaryCountsHiddenRecipients() {
        let none = AskAITools.sendDraftSummary(
            recipients: ["a@b.com"], subject: "Hi", hiddenCount: 0)
        XCTAssertEqual(none, "Send the draft to a@b.com — “Hi”.")

        let one = AskAITools.sendDraftSummary(
            recipients: ["a@b.com"], subject: "Hi", hiddenCount: 1)
        XCTAssertEqual(one, "Send the draft to a@b.com and 1 hidden recipient — “Hi”.")

        let two = AskAITools.sendDraftSummary(
            recipients: ["a@b.com"], subject: "Hi", hiddenCount: 2)
        XCTAssertEqual(two, "Send the draft to a@b.com and 2 hidden recipients — “Hi”.")
    }

    /// A Bcc-only draft still names a destination count, not a bare "the draft".
    func testSendDraftSummaryBccOnlyDraft() {
        let line = AskAITools.sendDraftSummary(
            recipients: [], subject: "Subj", hiddenCount: 1)
        XCTAssertEqual(line, "Send the draft to 1 hidden recipient — “Subj”.")
    }

    /// Long recipient lists and long subjects stay card-sized.
    func testSendDraftSummaryTrimsLongValues() {
        let many = (1...9).map { "user\($0)@example.com" }
        let line = AskAITools.sendDraftSummary(
            recipients: many, subject: String(repeating: "x", count: 200))
        XCTAssertTrue(line.contains("6 more"), line)
        XCTAssertTrue(line.contains("…"), line)
        XCTAssertLessThan(line.count, 160, line)
    }

    /// Bad JSON must still produce a card line — never an empty confirm.
    func testConfirmSummaryToleratesBadArguments() {
        let summary = AskAITools.confirmSummary(toolName: "add_vip", argumentsJSON: "not json")
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(summary.contains("add_vip"))
    }

    /// The Ask AI executor reuses the MCP dispatcher, so it must be callable.
    func testDispatchIsReachableFromAskAI() async throws {
        let tools = StubToolProvider()
        let text = try await MCPRouter.dispatch(
            name: "search_threads", args: ["query": .string("acme")], tools: tools)
        XCTAssertEqual(text, "searched:acme")
    }

    func testDispatchRejectsUnknownTool() async {
        do {
            _ = try await MCPRouter.dispatch(name: "nope", args: [:], tools: StubToolProvider())
            XCTFail("expected throw")
        } catch let error as MCPRouter.ToolDispatchError {
            guard case .unknownTool = error else {
                return XCTFail("expected unknownTool, got \(error)")
            }
        } catch {
            XCTFail("expected ToolDispatchError, got \(error)")
        }
    }
}

/// Minimal provider for the dispatch-visibility check.
private struct StubToolProvider: MCPToolProvider {
    func listAccounts() async throws -> String { "[]" }
    func listThreads(mailbox: String, unreadOnly: Bool?, limit: Int, offset: Int,
                     account: String?) async throws -> String { "[]" }
    func searchThreads(query: String, limit: Int, offset: Int) async throws -> String {
        "searched:\(query)"
    }
    func getThread(threadId: String) async throws -> String { "" }
    func listDrafts(account: String?) async throws -> String { "[]" }
    func createDraft(account: String, to: [String], cc: [String]?, bcc: [String]?,
                     subject: String, body: String,
                     replyToThreadId: String?) async throws -> String { "{}" }
    func setThreadSummary(threadId: String, summary: String,
                          model: String) async throws -> String { "{}" }
    func clearThreadSummary(threadId: String) async throws -> String { "{}" }
    func listVIPs() async throws -> String { "[]" }
    func addVIP(email: String, group: String?, groups: [String]?) async throws -> String { "{}" }
    func addVIPs(emails: [String], group: String?, groups: [String]?) async throws -> String { "{}" }
    func setVIPGroups(email: String, groups: [String]) async throws -> String { "{}" }
    func removeVIP(email: String) async throws -> String { "{}" }


    // MARK: - Confirm-card hiding tricks

    private func assertRunCollapsed(_ body: String, blank: Int,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let preview = AskAITools.confirmPreviewText(body)
        XCTAssertTrue(preview.contains("[\(blank) blank lines]"),
                      "got: \(preview.debugDescription)", file: file, line: line)
        XCTAssertTrue(preview.contains("secret"), file: file, line: line)
        XCTAssertLessThanOrEqual(preview.components(separatedBy: "\n").count, 3,
                                 file: file, line: line)
    }

    func testConfirmPreviewCollapsesCRLFRuns() {
        assertRunCollapsed("top" + String(repeating: "\r\n", count: 40) + "secret", blank: 39)
    }

    func testConfirmPreviewCollapsesBareCRRuns() {
        assertRunCollapsed("top" + String(repeating: "\r", count: 10) + "secret", blank: 9)
    }

    func testConfirmPreviewCollapsesUnicodeLineAndParagraphSeparators() {
        assertRunCollapsed("top" + String(repeating: "\u{2028}", count: 10) + "secret", blank: 9)
        assertRunCollapsed("top" + String(repeating: "\u{2029}", count: 10) + "secret", blank: 9)
    }

    func testConfirmPreviewCollapsesVerticalTabAndFormFeed() {
        assertRunCollapsed("top" + String(repeating: "\u{0B}", count: 10) + "secret", blank: 9)
        assertRunCollapsed("top" + String(repeating: "\u{0C}", count: 10) + "secret", blank: 9)
    }

    func testConfirmPreviewTreatsNBSPAndIdeographicSpaceLinesAsBlank() {
        assertRunCollapsed("top" + String(repeating: "\n\u{00A0}\u{00A0}", count: 10)
                           + "\nsecret", blank: 10)
        assertRunCollapsed("top" + String(repeating: "\n\u{3000}", count: 10)
                           + "\nsecret", blank: 10)
    }

    func testConfirmPreviewTreatsZeroWidthOnlyLinesAsBlank() {
        assertRunCollapsed("top" + String(repeating: "\n\u{200B}", count: 10)
                           + "\nsecret", blank: 10)
        assertRunCollapsed("top" + String(repeating: "\n\u{FEFF}\u{2060}", count: 10)
                           + "\nsecret", blank: 10)
    }

    func testConfirmPreviewKeepsSingleBlankLine() {
        XCTAssertEqual(AskAITools.confirmPreviewText("a\n\nb"), "a\n\nb")
    }

    func testConfirmPreviewRevealsInvisibleFormatCharacters() {
        let preview = AskAITools.confirmPreviewText("pay\u{200B}me \u{202E}evil\u{2066}x\u{FEFF}")
        XCTAssertTrue(preview.contains("⟨U+200B⟩"))
        XCTAssertTrue(preview.contains("⟨U+202E⟩"))
        XCTAssertTrue(preview.contains("⟨U+2066⟩"))
        XCTAssertTrue(preview.contains("⟨U+FEFF⟩"))
        for scalar in preview.unicodeScalars {
            XCTAssertFalse(AskAITools.isRevealedFormatCharacter(scalar.value))
        }
    }

    func testConfirmPreviewLineCountIncludesEmptyLines() {
        XCTAssertEqual(AskAITools.confirmPreviewLineCount("a\n\n\n\nb"), 5)
        XCTAssertEqual(AskAITools.confirmPreviewLineCount("a\r\n\r\nb"), 3)
        XCTAssertEqual(AskAITools.confirmPreviewLineCount("a\u{2028}b\u{0C}c"), 3)
        XCTAssertEqual(AskAITools.confirmPreviewLineCount("one"), 1)
    }
}

extension AskAIToolsTests {
    // MARK: - Confirm preview: more hiding tricks

    func testTagCharactersAreRevealed() {
        let hidden = "secret".unicodeScalars.map { Unicode.Scalar(0xE0000 + $0.value)! }
        var body = "OK"
        body.unicodeScalars.append(contentsOf: hidden)
        let preview = AskAITools.confirmPreviewText(body)
        XCTAssertTrue(preview.contains("⟨U+E0073⟩"), preview)
    }

    func testVariationSelectorsAndSoftHyphenAreRevealed() {
        let preview = AskAITools.confirmPreviewText("a\u{FE0F}b\u{00AD}c\u{061C}d")
        XCTAssertTrue(preview.contains("⟨U+FE0F⟩"))
        XCTAssertTrue(preview.contains("⟨U+00AD⟩"))
        XCTAssertTrue(preview.contains("⟨U+061C⟩"))
    }

    func testNonBreakingSpaceRunCollapses() {
        let gap = String(repeating: "\u{00A0}", count: 5000)
        let preview = AskAITools.confirmPreviewText("Thanks!\(gap)PS: hidden")
        XCTAssertTrue(preview.contains("⟨5000 spaces⟩"), preview)
        XCTAssertTrue(preview.contains("PS: hidden"))
        XCTAssertLessThan(preview.count, 100)
    }

    func testShortSpaceRunsStay() {
        XCTAssertEqual(AskAITools.confirmPreviewText("a  b"), "a  b")
    }

    func testCombiningMarkFloodIsCapped() {
        let flood = "e" + String(repeating: "\u{0301}", count: 500)
        let preview = AskAITools.confirmPreviewText(flood)
        XCTAssertTrue(preview.contains("⟨+497 marks⟩"), preview)
        XCTAssertLessThan(preview.unicodeScalars.count, 30)
    }

    func testOrdinaryAccentsSurvive() {
        XCTAssertEqual(AskAITools.confirmPreviewText("café naïve"), "café naïve")
    }
}
