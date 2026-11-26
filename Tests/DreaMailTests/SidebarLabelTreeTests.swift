import XCTest
import GRDB

/// The Gmail-style sidebar: the label tree, Gmail's list visibility, the
/// disclosure state, per-label unread counts, the Important and Spam views.
final class SidebarLabelTreeTests: XCTestCase {
    private let a = "a@x.com"
    private let b = "b@x.com"

    private func row(_ id: String, _ name: String, account: String = "a@x.com",
                     order: Int = LabelRow.unsorted, visibility: String? = nil) -> LabelRow {
        LabelRow(id: "\(account):\(id)", accountId: account, gmailLabelId: id, name: name,
                 type: "user", color: nil, sortOrder: order, listVisibility: visibility)
    }

    /// `name [children]` per node, for compact assertions.
    private func shape(_ nodes: [SidebarLabelNode]) -> [String] {
        nodes.map { n in
            n.children.isEmpty ? n.displayName
                : "\(n.displayName) [\(shape(n.children).joined(separator: ", "))]"
        }
    }

    // MARK: Tree

    func testSlashNestsUnderTheExistingParent() {
        let tree = SidebarLabelTree.build([
            row("L1", "mail"), row("L2", "mail/hotmail"), row("L3", "mail/yahoo"),
            row("L4", "dev"),
        ])
        XCTAssertEqual(shape(tree), ["dev", "mail [hotmail, yahoo]"])
        XCTAssertEqual(tree[1].children[0].fullName, "mail/hotmail")
        XCTAssertEqual(tree[1].children[0].gmailLabelId, "L2")
    }

    func testSeveralSlashesNestLevelByLevel() {
        let tree = SidebarLabelTree.build([
            row("L1", "a"), row("L2", "a/b"), row("L3", "a/b/c"), row("L4", "a/b/c/d"),
        ])
        XCTAssertEqual(shape(tree), ["a [b [c [d]]]"])
    }

    /// Gmail nests only under a label that exists: a missing level keeps its
    /// part of the path in the name.
    func testMissingParentKeepsThePath() {
        let tree = SidebarLabelTree.build([
            row("L1", "x/y"),          // no "x"
            row("L2", "a"),
            row("L3", "a/b/c"),        // no "a/b"
        ])
        XCTAssertEqual(shape(tree), ["a [b/c]", "x/y"])
        XCTAssertEqual(tree[0].children[0].fullName, "a/b/c")
    }

    /// `a/` under `a`: nothing after the slash, so the row keeps its name
    /// instead of an empty one.
    func testTrailingSlashKeepsTheFullName() {
        let tree = SidebarLabelTree.build([row("L1", "a"), row("L2", "a/")])
        XCTAssertEqual(shape(tree), ["a [a/]"])
    }

    func testEmptyPathPartsAreNotParents() {
        let tree = SidebarLabelTree.build([row("L1", "/lead"), row("L2", "a//b"), row("L3", "a")])
        // "a//b": its prefix "a/" is not a label; "a" is.
        XCTAssertEqual(shape(tree), ["/lead", "a [/b]"])
    }

    /// Gmail's order: case-insensitive, punctuation first (as in the owner's
    /// list: `$`, apple, …, juve, Notes, prenotazioni).
    func testSiblingsSortAsGmail() {
        let tree = SidebarLabelTree.build([
            row("L1", "uniba"), row("L2", "Notes"), row("L3", "juve"), row("L4", "$"),
            row("L5", "apple"), row("L6", "prenotazioni"),
        ])
        XCTAssertEqual(shape(tree), ["$", "apple", "juve", "Notes", "prenotazioni", "uniba"])
    }

    /// The organizer's order (Mac-only) comes first, then Gmail's.
    func testOrganizerOrderWins() {
        let tree = SidebarLabelTree.build([
            row("L1", "b", order: 1), row("L2", "a", order: 2), row("L3", "c"),
        ])
        XCTAssertEqual(shape(tree), ["b", "a", "c"])
    }

    func testColorsAreTheDisplayColors() {
        var r = row("L1", "work")
        r.gmailBackgroundColor = "#111111"
        r.color = "#222222"
        XCTAssertEqual(SidebarLabelTree.build([r])[0].colors.background, "#222222",
                       "the Mac-only color wins (DEC-023)")
    }

    func testHundredsOfLabelsBuildQuickly() {
        var rows: [LabelRow] = []
        for i in 0..<100 {
            rows.append(row("P\(i)", "p\(i)"))
            for j in 0..<5 { rows.append(row("C\(i)_\(j)", "p\(i)/c\(j)")) }
        }
        let start = Date()
        let tree = SidebarLabelTree.build(rows)
        XCTAssertEqual(tree.count, 100)
        XCTAssertEqual(tree.allSatisfy { $0.children.count == 5 }, true)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    // MARK: Visibility

    func testVisibilityRawValues() {
        XCTAssertEqual(SidebarLabelNode.Visibility(raw: nil), .show)
        XCTAssertEqual(SidebarLabelNode.Visibility(raw: "bogus"), .show)
        XCTAssertEqual(SidebarLabelNode.Visibility(raw: "labelHide"), .hide)
        XCTAssertEqual(SidebarLabelNode.Visibility(raw: "labelShowIfUnread"), .showIfUnread)
    }

    func testHiddenAndReadShowIfUnreadGoBehindMore() {
        let tree = SidebarLabelTree.build([
            row("L1", "shown"),
            row("L2", "hidden", visibility: "labelHide"),
            row("L3", "ifUnreadRead", visibility: "labelShowIfUnread"),
            row("L4", "ifUnreadUnread", visibility: "labelShowIfUnread"),
        ])
        let parts = SidebarLabelTree.split(tree) { $0.gmailLabelId == "L4" ? 2 : 0 }
        XCTAssertEqual(shape(parts.listed), ["ifUnreadUnread", "shown"])
        XCTAssertEqual(shape(parts.more), ["hidden", "ifUnreadRead"])
    }

    /// `shape`, with the labels revealed only by "More" marked `*`.
    private func marked(_ nodes: [SidebarLabelNode]) -> [String] {
        nodes.map { n in
            let name = n.displayName + (n.revealedByMore ? "*" : "")
            return n.children.isEmpty ? name : "\(name) [\(marked(n.children).joined(separator: ", "))]"
        }
    }

    /// What the sidebar draws: `listed`, then (More open) `more`, with the
    /// children `moreOpen` shows. Names and ids, in order.
    private func drawn(_ parts: SidebarLabelTree.Split, moreOpen: Bool) -> [SidebarLabelNode] {
        func flat(_ n: SidebarLabelNode) -> [SidebarLabelNode] {
            [n] + n.shownChildren(moreOpen: moreOpen).flatMap(flat)
        }
        return (parts.listed + (moreOpen ? parts.more : [])).flatMap(flat)
    }

    /// Nothing appears twice, More open or closed: no id repeats, `more` holds
    /// no label of `listed`, and nothing under `more` is revealed-only.
    private func assertNothingTwice(_ parts: SidebarLabelTree.Split,
                                    file: StaticString = #filePath, line: UInt = #line) {
        func ids(_ nodes: [SidebarLabelNode]) -> [String] {
            nodes.flatMap { [$0.id] + ids($0.children) }
        }
        let l = ids(parts.listed), m = ids(parts.more)
        XCTAssertEqual(Set(l).count, l.count, "listed has a repeat", file: file, line: line)
        XCTAssertEqual(Set(m).count, m.count, "more has a repeat", file: file, line: line)
        XCTAssertTrue(Set(l).isDisjoint(with: m), "a label is in both lists", file: file, line: line)
        XCTAssertTrue(parts.more.allSatisfy { !containsRevealed($0) },
                      "under More nothing is marked revealed-only", file: file, line: line)
        for open in [false, true] {
            let names = drawn(parts, moreOpen: open).map(\.id)
            XCTAssertEqual(Set(names).count, names.count, "a row is drawn twice", file: file, line: line)
        }
    }

    private func containsRevealed(_ n: SidebarLabelNode) -> Bool {
        n.revealedByMore || n.children.contains(where: containsRevealed)
    }

    /// Old: a listed child keeps its hidden parent as its container in the
    /// list, and the parent is repeated under "More"; a hidden child of a
    /// listed parent was a flat row "q/hidden" under "More" (#92).
    /// New: the container is not repeated; the hidden child is nested under
    /// its listed parent, with its short name, marked revealed-only.
    func testSplitKeepsTheTree() {
        let tree = SidebarLabelTree.build([
            row("L1", "p", visibility: "labelHide"), row("L2", "p/shown"),
            row("L3", "q"), row("L4", "q/hidden", visibility: "labelHide"), row("L5", "q/shown"),
        ])
        let parts = SidebarLabelTree.split(tree) { _ in 0 }
        XCTAssertEqual(marked(parts.listed), ["p [shown]", "q [hidden*, shown]"])
        XCTAssertTrue(parts.more.isEmpty)
        XCTAssertTrue(parts.needsMoreRow, "an in-place hidden sublabel needs the More row")
        assertNothingTwice(parts)
    }

    /// Old (#92): `more` = ["C/Sub", "Notes"], "C/Sub" a flat row named by
    /// its full name. New: "Sub" nested under "C"; `more` = ["Notes"].
    func testHiddenChildOfListedParentIsNestedUnderIt() throws {
        let tree = SidebarLabelTree.build([
            row("L1", "C"), row("L2", "C/Sub", visibility: "labelHide"),
            row("L3", "Notes", visibility: "labelHide"),
        ])
        let parts = SidebarLabelTree.split(tree) { _ in 0 }
        XCTAssertEqual(marked(parts.listed), ["C [Sub*]"])
        XCTAssertEqual(shape(parts.more), ["Notes"])
        let sub = try XCTUnwrap(parts.listed.first?.children.first)
        XCTAssertEqual(sub.fullName, "C/Sub", "help keeps the full name")
        XCTAssertEqual(sub.displayName, "Sub")
        XCTAssertEqual(sub.gmailLabelId, "L2")
        assertNothingTwice(parts)
    }

    /// The view's filter: a closed More shows no revealed-only child (and the
    /// parent has nothing to disclose); an open one shows it in order.
    func testShownChildrenFollowMore() throws {
        let tree = SidebarLabelTree.build([
            row("L1", "t"), row("L2", "t/a"), row("L3", "t/b", visibility: "labelHide"),
            row("L4", "t/c"),
        ])
        let t = try XCTUnwrap(SidebarLabelTree.split(tree) { _ in 0 }.listed.first)
        XCTAssertEqual(t.shownChildren(moreOpen: false).map(\.displayName), ["a", "c"])
        XCTAssertEqual(t.shownChildren(moreOpen: true).map(\.displayName), ["a", "b", "c"],
                       "in its normal sibling order")
    }

    /// Triangle rule: a listed parent whose sublabels are all hidden has
    /// something to show only while More is open.
    func testParentWithOnlyHiddenSublabelsHasNothingToShowWhileMoreIsClosed() throws {
        let tree = SidebarLabelTree.build([
            row("L1", "t"), row("L2", "t/a", visibility: "labelHide"),
            row("L3", "t/b", visibility: "labelHide"),
        ])
        let t = try XCTUnwrap(SidebarLabelTree.split(tree) { _ in 0 }.listed.first)
        XCTAssertTrue(t.shownChildren(moreOpen: false).isEmpty, "closed: no triangle")
        XCTAssertEqual(t.shownChildren(moreOpen: true).count, 2)
    }

    /// The More row: needed for below-More labels and for in-place ones;
    /// not needed when everything is listed.
    func testMoreRowNeededOnlyWhenSomethingIsHidden() {
        func needs(_ rows: [LabelRow]) -> Bool {
            SidebarLabelTree.split(SidebarLabelTree.build(rows)) { _ in 0 }.needsMoreRow
        }
        XCTAssertFalse(needs([row("L1", "a"), row("L2", "a/b")]))
        XCTAssertTrue(needs([row("L1", "a"), row("L2", "a/b", visibility: "labelHide")]),
                      "only an in-place sublabel is hidden")
        XCTAssertTrue(needs([row("L1", "a"), row("L2", "z", visibility: "labelHide")]),
                      "only a top-level label is hidden")
        XCTAssertFalse(needs([row("L1", "h", visibility: "labelHide"), row("L2", "h/s")]),
                       "a container of a listed label is listed")
    }

    func testListedChildUnderHiddenParentDoesNotRepeatTheParent() {
        let tree = SidebarLabelTree.build([
            row("L1", "h", visibility: "labelHide"), row("L2", "h/shown"),
        ])
        let parts = SidebarLabelTree.split(tree) { _ in 0 }
        XCTAssertEqual(marked(parts.listed), ["h [shown]"])
        XCTAssertTrue(parts.more.isEmpty)
        XCTAssertFalse(parts.needsMoreRow)
        assertNothingTwice(parts)
    }

    /// Old (#92): listed = ["a [d [e]]"], more = ["a/b [c]", "a/d/f"].
    /// New: a hidden subtree under a listed parent nests in place, revealed
    /// only: listed = ["a [b* [c*], d [e, f*]]"], more empty.
    func testThreeLevels() {
        let tree = SidebarLabelTree.build([
            row("L1", "a"),
            row("L2", "a/b", visibility: "labelHide"),
            row("L3", "a/b/c", visibility: "labelHide"),
            row("L4", "a/d", visibility: "labelHide"),
            row("L5", "a/d/e"),
            row("L6", "a/d/f", visibility: "labelHide"),
        ])
        let parts = SidebarLabelTree.split(tree) { _ in 0 }
        XCTAssertEqual(marked(parts.listed), ["a [b* [c*], d [e, f*]]"])
        XCTAssertTrue(parts.more.isEmpty)
        assertNothingTwice(parts)
    }

    /// A hidden grandparent kept as the container of a listed child; that
    /// child's hidden child nests under it, revealed only.
    func testHiddenChildOfListedChildOfHiddenGrandparent() {
        let tree = SidebarLabelTree.build([
            row("L1", "g", visibility: "labelHide"), row("L2", "g/c"),
            row("L3", "g/c/h", visibility: "labelHide"),
        ])
        let parts = SidebarLabelTree.split(tree) { _ in 0 }
        XCTAssertEqual(marked(parts.listed), ["g [c [h*]]"])
        XCTAssertTrue(parts.more.isEmpty)
        XCTAssertTrue(parts.needsMoreRow)
        assertNothingTwice(parts)
    }

    /// Old (#92): rows under "More" carried full names ("clients/2024/archive").
    /// New: nested under their listed parents with the same short name, so no
    /// name needs a path and nothing is repeated.
    func testSameShortNameUnderTwoParentsStaysNested() {
        let tree = SidebarLabelTree.build([
            row("L1", "clients"), row("L2", "clients/2024"),
            row("L3", "clients/2024/archive", visibility: "labelHide"),
            row("L4", "projects"), row("L5", "projects/2024"),
            row("L6", "projects/2024/archive", visibility: "labelHide"),
        ])
        let parts = SidebarLabelTree.split(tree) { _ in 0 }
        XCTAssertEqual(marked(parts.listed),
                       ["clients [2024 [archive*]]", "projects [2024 [archive*]]"])
        XCTAssertTrue(parts.more.isEmpty)
        assertNothingTwice(parts)
    }

    /// Top-level hidden labels keep their subtree nested under More.
    func testTopLevelHiddenSubtreeStaysNestedUnderMore() {
        let tree = SidebarLabelTree.build([
            row("L1", "x", visibility: "labelHide"), row("L2", "x/y", visibility: "labelHide"),
        ])
        let parts = SidebarLabelTree.split(tree) { _ in 0 }
        XCTAssertTrue(parts.listed.isEmpty)
        XCTAssertEqual(marked(parts.more), ["x [y]"])
        XCTAssertFalse(parts.hasRevealedInPlace)
        XCTAssertTrue(parts.needsMoreRow)
    }

    /// Every visibility combination, unread or not, More open and closed:
    /// nothing appears twice and no row is named with a path.
    func testNothingIsListedTwiceWhateverTheVisibility() {
        let kinds = ["labelShow", "labelHide", "labelShowIfUnread"]
        for pv in kinds { for cv in kinds { for gv in kinds {
            let tree = SidebarLabelTree.build([
                row("L1", "p", visibility: pv), row("L2", "p/c", visibility: cv),
                row("L3", "p/c/g", visibility: gv), row("L4", "p/x", visibility: cv),
            ])
            for unread in [0, 3] {
                let parts = SidebarLabelTree.split(tree) { _ in unread }
                assertNothingTwice(parts)
                for open in [false, true] {
                    XCTAssertTrue(drawn(parts, moreOpen: open).allSatisfy { !$0.displayName.contains("/") },
                                  "\(pv) \(cv) \(gv): a row is named with a path")
                }
            }
        } } }
    }

    func testEverythingShownLeavesMoreEmpty() {
        let tree = SidebarLabelTree.build([row("L1", "a"), row("L2", "a/b")])
        let parts = SidebarLabelTree.split(tree) { _ in 0 }
        XCTAssertTrue(parts.more.isEmpty)
        XCTAssertFalse(parts.needsMoreRow)
    }

    // MARK: Disclosure state

    private func defaults() throws -> (UserDefaults, String) {
        let suite = "SidebarLabelTreeTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testDisclosureStateRoundTripsAndStoresNoNames() throws {
        let (d, suite) = try defaults()
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertFalse(SidebarDisclosure.isMoreExpanded(d), "More starts closed")
        SidebarDisclosure.setMoreExpanded(true, d)
        XCTAssertTrue(SidebarDisclosure.isMoreExpanded(d))
        SidebarDisclosure.setMoreExpanded(false, d)
        XCTAssertNil(d.object(forKey: SidebarDisclosure.moreKey), "closed is not stored")

        SidebarDisclosure.setLabel("Label_7", accountId: a, expanded: true, d)
        SidebarDisclosure.setLabel("Label_9", accountId: a, expanded: true, d)
        SidebarDisclosure.setLabel("Label_9", accountId: a, expanded: false, d)
        XCTAssertEqual(SidebarDisclosure.expandedLabels(accountId: a, d), ["Label_7"])
        XCTAssertEqual(SidebarDisclosure.expandedLabels(accountId: b, d), [])
        XCTAssertEqual(d.stringArray(forKey: SidebarDisclosure.expandedLabelsKey(accountId: a)),
                       ["Label_7"], "label ids only, never names")
        SidebarDisclosure.setLabel("Label_7", accountId: a, expanded: false, d)
        XCTAssertNil(d.object(forKey: SidebarDisclosure.expandedLabelsKey(accountId: a)))
    }

    /// "Deleted means gone" (DEC-019): removing an account removes its
    /// sidebar state, and only its own.
    func testDisclosureStateGoesWithTheAccount() throws {
        let (d, suite) = try defaults()
        defer { d.removePersistentDomain(forName: suite) }
        for id in [a, b, "a@x.com.au"] {
            SidebarDisclosure.setLabel("Label_1", accountId: id, expanded: true, d)
            SidebarDisclosure.setFlag(SidebarDisclosure.labelsMoreKey(accountId: id), true, d)
            SidebarDisclosure.setFlag(SidebarDisclosure.accountCollapsedKey(accountId: id), true, d)
        }
        SidebarDisclosure.setMoreExpanded(true, d)

        AccountLifecycle.clearAccountDefaults(accountId: a, defaults: d)

        for key in SidebarDisclosure.keys(accountId: a) {
            XCTAssertNil(d.object(forKey: key), key)
        }
        for id in [b, "a@x.com.au"] {
            XCTAssertEqual(SidebarDisclosure.expandedLabels(accountId: id, d), ["Label_1"], id)
            XCTAssertTrue(SidebarDisclosure.flag(SidebarDisclosure.labelsMoreKey(accountId: id), d))
            XCTAssertTrue(SidebarDisclosure.flag(
                SidebarDisclosure.accountCollapsedKey(accountId: id), d))
        }
        XCTAssertTrue(SidebarDisclosure.isMoreExpanded(d), "not an account's key")
    }

    // MARK: New label

    /// Switching account leaves another account's label for the Inbox.
    func testLabelViewFollowsTheAccountSwitch() {
        let labelOfA = MailboxView.label(account: a, labelId: "Label_1", name: "x")
        XCTAssertEqual(SidebarScope.view(labelOfA, afterSwitchingTo: b), .inbox)
        XCTAssertEqual(SidebarScope.view(labelOfA, afterSwitchingTo: a), labelOfA)
        XCTAssertEqual(SidebarScope.view(labelOfA, afterSwitchingTo: nil), labelOfA,
                       "all accounts in scope: the label still has its mail")
        XCTAssertEqual(SidebarScope.view(.starred, afterSwitchingTo: b), .starred)
    }

    func testNewLabelName() {
        XCTAssertNil(NewLabelName.full(name: "  ", parent: nil))
        XCTAssertEqual(NewLabelName.full(name: " fastweb ", parent: nil), "fastweb")
        XCTAssertEqual(NewLabelName.full(name: "fastweb", parent: "mail"), "mail/fastweb")
        XCTAssertEqual(NewLabelName.full(name: "fastweb", parent: ""), "fastweb")
        XCTAssertTrue(NewLabelName.exists("Mail/Fastweb", in: [row("L1", "mail/fastweb")]))
        XCTAssertFalse(NewLabelName.exists("mail", in: [row("L1", "mail/fastweb")]))
        XCTAssertEqual(NewLabelName.full(name: "/x/", parent: "mail"), "mail/x")
        XCTAssertNil(NewLabelName.full(name: " / ", parent: "mail"))
    }

    /// A parent picked on one account must never be created on another:
    /// the dialog's check refuses a parent that is not the account's own.
    func testNewLabelParentMustBelongToTheAccount() {
        let accountA = [row("L1", "private-a", account: a)]
        let accountB = [row("L2", "work", account: b)]
        XCTAssertEqual(NewLabelName.check(name: "x", nest: true, parent: "private-a", rows: accountB),
                       .unknownParent)
        XCTAssertEqual(NewLabelName.check(name: "x", nest: true, parent: "private-a", rows: accountA),
                       .ok("private-a/x"))
        XCTAssertEqual(NewLabelName.check(name: "x", nest: true, parent: "", rows: accountB),
                       .unknownParent)
        // Not nesting: the stale parent is ignored.
        XCTAssertEqual(NewLabelName.check(name: "x", nest: false, parent: "private-a", rows: accountB),
                       .ok("x"))
        XCTAssertEqual(NewLabelName.check(name: "Work", nest: false, parent: "", rows: accountB),
                       .duplicate)
        XCTAssertEqual(NewLabelName.check(name: "  ", nest: false, parent: "", rows: accountB), .empty)
    }

    // MARK: Database

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            for id in [a, b] {
                try Account(id: id, displayName: "P", historyId: nil,
                            lastSyncAt: nil, senderName: "").insert(db)
            }
        }
        return q
    }

    private func insert(_ db: Database, _ id: String, account: String, unread: Bool,
                        trash: Bool = false, spam: Bool = false,
                        labels: [String] = []) throws {
        var system = ["INBOX"]
        if spam { system = ["SPAM"] }
        if trash { system = ["TRASH"] }
        try MailThread(
            id: "\(account):\(id)", accountId: account, gmailThreadId: id,
            subject: "s", snippet: "sn", fromDisplay: "F",
            lastDate: Date(), isUnread: unread, isStarred: false,
            inInbox: !spam && !trash, inTrash: trash,
            labelIds: (system + labels).joined(separator: " "), snoozeUntil: nil,
            participants: "F", messageCount: 1, hasAttachment: false, reminderAt: nil,
            inSpam: spam).insert(db)
        for label in labels where label.hasPrefix("Label_") {
            try ThreadLabel(threadId: "\(account):\(id)", labelId: label).insert(db)
        }
    }

    func testPerLabelUnreadIsOneGroupedCount() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insert(db, "t1", account: a, unread: true, labels: ["Label_1"])
            try self.insert(db, "t2", account: a, unread: true, labels: ["Label_1", "Label_2"])
            try self.insert(db, "t3", account: a, unread: false, labels: ["Label_1"])
            try self.insert(db, "t4", account: a, unread: true, trash: true, labels: ["Label_1"])
            try self.insert(db, "t5", account: a, unread: true, spam: true, labels: ["Label_1"])
            // Same Gmail id on another account: its own count.
            try self.insert(db, "t6", account: b, unread: true, labels: ["Label_1"])
        }
        let all = try q.read { try SidebarCounts.fetchLabelUnread(db: $0, account: nil) }
        XCTAssertEqual(all, ["label:a@x.com:Label_1": 2, "label:a@x.com:Label_2": 1,
                             "label:b@x.com:Label_1": 1])
        let scoped = try q.read { try SidebarCounts.fetchLabelUnread(db: $0, account: b) }
        XCTAssertEqual(scoped, ["label:b@x.com:Label_1": 1])

        let counts = try q.read {
            try SidebarCounts.fetch(db: $0, activeAccount: a, badgeAccount: a).counts
        }
        XCTAssertEqual(counts["label:a@x.com:Label_1"], 2, "published with the sidebar counts")
        XCTAssertNil(counts["label:b@x.com:Label_1"])
        XCTAssertEqual(counts["spam"], 1)
    }

    /// The optimistic badge path agrees with the database counts.
    func testMembershipsCarryLabelAndSpamKeys() {
        var t = MailThread(
            id: "a@x.com:t1", accountId: a, gmailThreadId: "t1", subject: "s", snippet: "",
            fromDisplay: "F", lastDate: Date(), isUnread: true, isStarred: false,
            inInbox: true, inTrash: false, labelIds: "INBOX Label_1 IMPORTANT",
            snoozeUntil: nil, participants: "F", messageCount: 1, hasAttachment: false,
            reminderAt: nil)
        XCTAssertTrue(SidebarCounts.memberships(of: t).contains("label:a@x.com:Label_1"))
        XCTAssertFalse(SidebarCounts.memberships(of: t).contains("spam"))
        t.inSpam = true
        XCTAssertFalse(SidebarCounts.memberships(of: t).contains("label:a@x.com:Label_1"))
        XCTAssertTrue(SidebarCounts.memberships(of: t).contains("spam"))
        t.isUnread = false
        XCTAssertFalse(SidebarCounts.memberships(of: t).contains("spam"))
    }

    private func plan(_ db: Database, _ sql: String,
                      _ args: StatementArguments = StatementArguments()) throws -> String {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: args)
            .map { $0["detail"] as String? ?? "" }.joined(separator: " | ")
    }

    /// One indexed pass, never a full scan of `thread` per label.
    func testPerLabelUnreadUsesTheV65Index() throws {
        let q = try makeDB()
        try q.read { db in
            let scopes: [(String, StatementArguments)] = [
                ("", StatementArguments()), ("thread.accountId = ? AND ", [self.a]),
            ]
            for (scope, args) in scopes {
                let detail = try self.plan(
                    db, SidebarCounts.labelUnreadQuery(scoped: !scope.isEmpty), args)
                XCTAssertTrue(detail.contains("thread_unread_live"), detail)
                XCTAssertTrue(detail.contains("thread_label USING COVERING INDEX"), detail)
            }
            let spam = try self.plan(db, """
                SELECT COUNT(*) FROM thread WHERE accountId = ? AND (isUnread = 1 AND inSpam = 1)
                """, [self.a])
            XCTAssertTrue(spam.contains("thread_unread_spam"), spam)
        }
    }

    func testImportantAndSpamViews() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insert(db, "imp", account: a, unread: false, labels: ["IMPORTANT"])
            try self.insert(db, "impTrash", account: a, unread: false, trash: true,
                            labels: ["IMPORTANT"])
            try self.insert(db, "impSpam", account: a, unread: false, spam: true,
                            labels: ["IMPORTANT"])
            // A label id that merely contains the word is not the system label.
            try self.insert(db, "lookalike", account: a, unread: false,
                            labels: ["Label_IMPORTANTX"])
            try self.insert(db, "plain", account: a, unread: false)
        }
        let important = try q.read { try ThreadListQuery.important().fetchAll($0).map(\.gmailThreadId) }
        XCTAssertEqual(important, ["imp"])
        let spam = try q.read { try ThreadListQuery.spam().fetchAll($0).map(\.gmailThreadId) }
        XCTAssertEqual(spam, ["impSpam"])
    }

    func testLabelSyncStoresGmailVisibility() throws {
        let q = try makeDB()
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: self.a, labels: [
                GLabel(id: "Label_1", name: "shown", type: "user", color: nil,
                       labelListVisibility: "labelShow"),
                GLabel(id: "Label_2", name: "hidden", type: "user", color: nil,
                       labelListVisibility: "labelHide"),
                GLabel(id: "Label_3", name: "none", type: "user", color: nil),
            ])
        }
        let stored = try q.read { db in
            try LabelRow.filter(Column("accountId") == self.a).fetchAll(db)
        }
        let byId = Dictionary(uniqueKeysWithValues: stored.map { ($0.gmailLabelId, $0) })
        XCTAssertEqual(byId["Label_1"]?.listVisibility, "labelShow")
        XCTAssertEqual(byId["Label_2"]?.listVisibility, "labelHide")
        XCTAssertNil(byId["Label_3"]?.listVisibility)

        // Changed in Gmail: the next sync follows.
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: self.a, labels: [
                GLabel(id: "Label_1", name: "shown", type: "user", color: nil,
                       labelListVisibility: "labelShowIfUnread"),
            ])
        }
        let after = try q.read { try LabelRow.fetchOne($0, key: "a@x.com:Label_1") }
        XCTAssertEqual(after?.listVisibility, "labelShowIfUnread")
    }

    func testGmailLabelListDecodesVisibility() throws {
        let json = Data("""
            {"labels":[{"id":"Label_1","name":"mail/pec","type":"user",
                        "labelListVisibility":"labelShowIfUnread"},
                       {"id":"INBOX","name":"INBOX","type":"system"}]}
            """.utf8)
        let list = try JSONDecoder().decode(GLabelList.self, from: json)
        XCTAssertEqual(list.labels?.first?.labelListVisibility, "labelShowIfUnread")
        XCTAssertNil(list.labels?.last?.labelListVisibility)
    }
}

/// v65 (this branch) registers after v63 and v64; v62 is still to land on
/// `main`. A database that already ran every other migration must still get
/// v65.
final class SidebarMigrationOrderTests: XCTestCase {
    func testV65RunsOnADatabaseThatAlreadyHasTheOthers() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        // Make it the database of a build without v65.
        try q.write { db in
            try db.execute(sql: "DROP INDEX thread_unread_live")
            try db.execute(sql: "DROP INDEX thread_unread_spam")
            try db.alter(table: "label") { t in t.drop(column: "listVisibility") }
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v65'")
        }
        try q.read { db in
            let applied = try AppDatabase.migrator.appliedIdentifiers(db)
            XCTAssertTrue(applied.contains("v64"))
            XCTAssertFalse(applied.contains("v65"))
        }
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            XCTAssertTrue(try AppDatabase.migrator.appliedIdentifiers(db).contains("v65"))
            XCTAssertTrue(try db.columns(in: "label").contains { $0.name == "listVisibility" })
            XCTAssertTrue(try db.indexes(on: "thread").contains { $0.name == "thread_unread_live" })
            XCTAssertTrue(try db.indexes(on: "thread").contains { $0.name == "thread_unread_spam" })
            XCTAssertTrue(try AppDatabase.migrator.hasCompletedMigrations(db))
        }
    }
}
