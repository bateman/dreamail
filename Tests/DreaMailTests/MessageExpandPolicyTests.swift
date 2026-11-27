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

    /// A starred conversation opens several cards in the reading pane: a
    /// click closes or opens only the card clicked.
    func testSingleWithSeveralOpenTogglesOnlyTheClickedCard() {
        let open: Set<String> = ["a", "c", "d"]
        XCTAssertEqual(MessageExpandPolicy.single.applyingToggle(id: "d", currently: open), ["a", "c"])
        XCTAssertEqual(MessageExpandPolicy.single.applyingToggle(id: "b", currently: open),
                       ["a", "b", "c", "d"], "opening one does not close the others")
        XCTAssertEqual(MessageExpandPolicy.single.applyingExpand(id: "b", currently: open),
                       ["a", "b", "c", "d"])
        // Back to one open card: the usual single behaviour.
        XCTAssertEqual(MessageExpandPolicy.single.applyingToggle(id: "a", currently: ["a"]), [])
        XCTAssertEqual(MessageExpandPolicy.single.applyingToggle(id: "b", currently: ["a"]), ["b"])
        XCTAssertEqual(MessageExpandPolicy.single.applyingExpand(id: "b", currently: ["a"]), ["b"])
    }

    /// Without a starred message every open card fills the pane while it
    /// loads, as before; with one, only the scroll target.
    func testFillsPaneWithSeveralOpenCards() {
        let open: Set<String> = ["m1", "m2"]
        for id in open {
            XCTAssertTrue(MessageExpandPolicy.fillsPane(
                id: id, policy: .single, expanded: open, lastNonDraftId: "m2"), id)
        }
        XCTAssertTrue(MessageExpandPolicy.fillsPane(
            id: "m1", policy: .single, expanded: open, lastNonDraftId: "m2", scrollTargetId: "m1"))
        XCTAssertFalse(MessageExpandPolicy.fillsPane(
            id: "m2", policy: .single, expanded: open, lastNonDraftId: "m2", scrollTargetId: "m1"))
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

    private func firstFrame(_ messages: [Message],
                            _ policy: MessageExpandPolicy) -> Set<String> {
        let roles = ThreadMessageRoles(messages: messages)
        return MessageExpandPolicy.initialExpandedIds(
            policy: policy, nonDraftIds: roles.nonDraftIds,
            lastNonDraftId: roles.lastNonDraftId)
    }

    /// Runs the pane's open sequence — `init` seed, load-task start, payload
    /// apply — the way `ThreadDetailView` does, and returns the open set
    /// after each step.
    private func openSequence(mirror: [Message], payload: [Message],
                              policy: MessageExpandPolicy = .single,
                              threadId: String = "a:t1") -> [Set<String>] {
        let seeded = firstFrame(mirror, policy)
        let atLoad = MessageExpandPolicy.keptAtLoadStart(
            current: seeded, messageThreadIds: mirror.map(\.threadId),
            threadId: threadId)
        let roles = ThreadMessageRoles(messages: payload)
        let applied = MessageExpandPolicy.applyingPayload(
            current: atLoad, policy: policy,
            nonDraftIds: roles.nonDraftIds, lastNonDraftId: roles.lastNonDraftId)
        return [seeded, atLoad, applied]
    }

    /// The reported bug: the pane seeded from the warm mirror painted its
    /// first frame with no card open, and the load task cleared the set again
    /// until the payload landed. A one-message conversation is open at every
    /// step.
    func testOneMessageConversationIsOpenAtEveryStepOfTheOpen() {
        XCTAssertEqual(openSequence(mirror: [msg("1")], payload: [msg("1")]),
                       [["a:1"], ["a:1"], ["a:1"]])
        XCTAssertEqual(
            openSequence(mirror: [msg("1")], payload: [msg("1")], policy: .multiple),
            [["a:1"], ["a:1"], ["a:1"]])
    }

    func testColdOpenWithoutMirrorOpensOnPayload() {
        XCTAssertEqual(openSequence(mirror: [], payload: [msg("1")]),
                       [[], [], ["a:1"]])
    }

    func testPayloadWithANewerMessageKeepsTheSeededCardWhileItIsLive() {
        // The newest from the mirror is still in the thread: it stays open
        // rather than flipping to the newer one under the user's eyes.
        let steps = openSequence(mirror: [msg("1")],
                                 payload: [msg("1"), msg("2", offset: 10)])
        XCTAssertEqual(steps.last, ["a:1"])
        // A seeded id that left the thread falls back to the payload's newest.
        XCTAssertEqual(
            openSequence(mirror: [msg("old")], payload: [msg("new")]).last,
            ["a:new"])
    }

    func testSideBySideSwitchStartsFromAnEmptySet() {
        // The column still holds another conversation's messages.
        XCTAssertEqual(
            MessageExpandPolicy.keptAtLoadStart(
                current: ["a:1"], messageThreadIds: ["a:t1"], threadId: "a:t2"),
            [])
    }

    func testFirstFrameMatchesTheLoadDefaultForLongerThreads() {
        let thread = [msg("1"), msg("2", offset: 10), msg("3", offset: 20)]
        XCTAssertEqual(firstFrame(thread, .single), ["a:3"],
                       "reading pane: newest open, older collapsed")
        XCTAssertEqual(firstFrame(thread, .multiple), ["a:1", "a:2", "a:3"],
                       "side-by-side: every sent card open")
        XCTAssertEqual(openSequence(mirror: thread, payload: thread).last, ["a:3"])
        XCTAssertEqual(
            openSequence(mirror: thread, payload: thread, policy: .multiple).last,
            ["a:1", "a:2", "a:3"])
    }

    func testFirstFrameSkipsDrafts() {
        // A trailing draft is a DraftMessageCard, never the open card.
        XCTAssertEqual(firstFrame([msg("1"), msg("d", labels: "DRAFT", offset: 10)], .single),
                       ["a:1"])
        // Draft-only conversation: nothing to open, no MessageCard at all.
        XCTAssertEqual(firstFrame([msg("d", labels: "DRAFT")], .single), [])
        XCTAssertEqual(firstFrame([], .single), [])
    }

    func testOnlyTheOpenCardFillsThePane() {
        XCTAssertTrue(MessageExpandPolicy.fillsPane(
            id: "m2", policy: .single, expanded: ["m2"], lastNonDraftId: "m2"))
        XCTAssertFalse(MessageExpandPolicy.fillsPane(
            id: "m1", policy: .single, expanded: ["m2"], lastNonDraftId: "m2"))
        // Side-by-side opens every card; only the newest claims the pane.
        XCTAssertTrue(MessageExpandPolicy.fillsPane(
            id: "m2", policy: .multiple, expanded: ["m1", "m2"], lastNonDraftId: "m2"))
        XCTAssertFalse(MessageExpandPolicy.fillsPane(
            id: "m1", policy: .multiple, expanded: ["m1", "m2"], lastNonDraftId: "m2"))
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

