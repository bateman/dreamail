import XCTest

/// Hostless suite: pure expand-set policy for reading pane vs side-by-side.
final class MessageExpandPolicyTests: XCTestCase {

    func testSingleToggleOpensAndClosesOne() {
        let policy = MessageExpandPolicy.single
        let opened = policy.applyingToggle(id: "a", currently: [])
        XCTAssertEqual(opened, ["a"])
        let closed = policy.applyingToggle(id: "a", currently: opened)
        XCTAssertEqual(closed, [])
    }

    func testSingleExpandReplacesSibling() {
        let policy = MessageExpandPolicy.single
        let next = policy.applyingExpand(id: "b", currently: ["a"])
        XCTAssertEqual(next, ["b"])
        let toggled = policy.applyingToggle(id: "c", currently: ["b"])
        XCTAssertEqual(toggled, ["c"])
    }

    func testMultipleToggleKeepsSiblings() {
        let policy = MessageExpandPolicy.multiple
        let a = policy.applyingToggle(id: "a", currently: [])
        let ab = policy.applyingToggle(id: "b", currently: a)
        XCTAssertEqual(ab, ["a", "b"])
        let onlyB = policy.applyingToggle(id: "a", currently: ab)
        XCTAssertEqual(onlyB, ["b"])
    }

    func testMultipleExpandAddsWithoutCollapsing() {
        let policy = MessageExpandPolicy.multiple
        let next = policy.applyingExpand(id: "b", currently: ["a"])
        XCTAssertEqual(next, ["a", "b"])
        // Already open is a no-op insert.
        XCTAssertEqual(policy.applyingExpand(id: "a", currently: next), ["a", "b"])
    }

    func testInitialExpandedIdsSingleUsesLastOnly() {
        let ids = MessageExpandPolicy.initialExpandedIds(
            policy: .single,
            nonDraftIds: ["m1", "m2", "m3"],
            lastNonDraftId: "m3")
        XCTAssertEqual(ids, ["m3"])
    }

    func testInitialExpandedIdsSingleEmptyWhenNoLast() {
        let ids = MessageExpandPolicy.initialExpandedIds(
            policy: .single,
            nonDraftIds: ["m1"],
            lastNonDraftId: nil)
        XCTAssertEqual(ids, [])
    }

    func testInitialExpandedIdsMultipleOpensAllNonDrafts() {
        let ids = MessageExpandPolicy.initialExpandedIds(
            policy: .multiple,
            nonDraftIds: ["m1", "m2", "m3"],
            lastNonDraftId: "m3")
        XCTAssertEqual(ids, ["m1", "m2", "m3"])
    }

    func testInitialExpandedIdsMultipleEmptyThread() {
        let ids = MessageExpandPolicy.initialExpandedIds(
            policy: .multiple,
            nonDraftIds: [],
            lastNonDraftId: nil)
        XCTAssertEqual(ids, [])
    }

    // MARK: - One-message conversations (always open)

    private func msg(_ id: String, labels: String = "INBOX",
                     offset: TimeInterval = 0) -> Message {
        Message(
            id: "a:\(id)", accountId: "a", gmailId: id,
            threadId: "a:t1", fromHeader: "Ron <a@x.com>", toHeader: "b@x.com",
            ccHeader: "", bccHeader: "", subject: "Hi",
            date: Date(timeIntervalSince1970: 1_783_372_500 + offset),
            snippet: "", bodyText: "body \(id)", bodyHTML: nil,
            messageIdHeader: "<\(id)@mail>", referencesHeader: "",
            labelIds: labels, isUnread: false, hasAttachment: false)
    }

    /// The reported bug: the pane seeded from the warm mirror painted its
    /// first frame with no card open, so a one-message conversation showed a
    /// header-only row. The first frame must already open it.
    func testFirstFrameOpensTheOnlyMessage() {
        XCTAssertEqual(
            MessageExpandPolicy.firstFrameExpandedIds(
                messages: [msg("1")], policy: .single),
            ["a:1"])
        XCTAssertEqual(
            MessageExpandPolicy.firstFrameExpandedIds(
                messages: [msg("1")], policy: .multiple),
            ["a:1"])
    }

    func testFirstFrameMatchesTheLoadDefaultForLongerThreads() {
        let thread = [msg("1"), msg("2", offset: 10), msg("3", offset: 20)]
        XCTAssertEqual(
            MessageExpandPolicy.firstFrameExpandedIds(messages: thread, policy: .single),
            ["a:3"], "reading pane: newest open, older collapsed")
        XCTAssertEqual(
            MessageExpandPolicy.firstFrameExpandedIds(messages: thread, policy: .multiple),
            ["a:1", "a:2", "a:3"], "side-by-side: every sent card open")
    }

    func testFirstFrameSkipsDrafts() {
        // A trailing draft is a DraftMessageCard, never the open card.
        XCTAssertEqual(
            MessageExpandPolicy.firstFrameExpandedIds(
                messages: [msg("1"), msg("d", labels: "DRAFT", offset: 10)],
                policy: .single),
            ["a:1"])
        // Draft-only conversation: nothing to open, no MessageCard at all.
        XCTAssertEqual(
            MessageExpandPolicy.firstFrameExpandedIds(
                messages: [msg("d", labels: "DRAFT")], policy: .single),
            [])
        XCTAssertEqual(
            MessageExpandPolicy.firstFrameExpandedIds(messages: [], policy: .single),
            [])
    }

    func testSoleCardIsNotCollapsible() {
        XCTAssertFalse(MessageExpandPolicy.isCollapsible(id: "m1", nonDraftIds: ["m1"]))
        XCTAssertTrue(MessageExpandPolicy.isCollapsible(id: "m2", nonDraftIds: ["m1", "m2"]))
        XCTAssertTrue(MessageExpandPolicy.isCollapsible(id: "m1", nonDraftIds: ["m1", "m2"]))
        XCTAssertNil(MessageExpandPolicy.soleCardId(nonDraftIds: []))
        XCTAssertNil(MessageExpandPolicy.soleCardId(nonDraftIds: ["m1", "m2"]))
        XCTAssertEqual(MessageExpandPolicy.soleCardId(nonDraftIds: ["m1"]), "m1")
    }

    func testRefreshReopensARenumberedSoleMessage() {
        // Send / Gmail re-id replaces the only message's id.
        XCTAssertEqual(
            MessageExpandPolicy.reconciledAfterRefresh(
                current: ["old"], nonDraftIds: ["new"]),
            ["new"])
    }

    func testRefreshKeepsAManualCollapseInLongerThreads() {
        XCTAssertEqual(
            MessageExpandPolicy.reconciledAfterRefresh(
                current: [], nonDraftIds: ["m1", "m2"]),
            [])
        XCTAssertEqual(
            MessageExpandPolicy.reconciledAfterRefresh(
                current: ["m1", "gone"], nonDraftIds: ["m1", "m2"]),
            ["m1"])
    }
}

