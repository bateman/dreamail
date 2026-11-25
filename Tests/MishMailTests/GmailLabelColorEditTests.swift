import XCTest
import GRDB

/// Changing a label's color on Gmail: the palette the API accepts, the
/// labels.patch body, the optimistic write with its restore, no bounce from
/// a sync, the Mac-only color's precedence, and system labels.
final class GmailLabelColorEditTests: XCTestCase {
    private let account = "a@x.com"
    private var rowId: String { "\(account):Label_1" }

    private func makeDB(gmail: LabelColors = .none, type: String = "user",
                        gmailId: String = "Label_1") throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            try LabelRow(id: "\(account):\(gmailId)", accountId: account, gmailLabelId: gmailId,
                         name: "Work", type: type, color: nil,
                         gmailBackgroundColor: gmail.background, gmailTextColor: gmail.text).save(db)
        }
        return q
    }

    private func row(_ q: DatabaseQueue, _ id: String? = nil) throws -> LabelRow {
        try XCTUnwrap(try q.read { db in try LabelRow.fetchOne(db, key: id ?? rowId) })
    }

    private func gmailColors(_ q: DatabaseQueue) throws -> LabelColors {
        let r = try row(q)
        return LabelColors(background: r.gmailBackgroundColor, text: r.gmailTextColor)
    }

    private func answer(_ colors: LabelColors?, id: String = "Label_1") -> GLabel {
        GLabel(id: id, name: "Work", type: "user",
               color: colors.map { GLabel.GColor(backgroundColor: $0.background, textColor: $0.text) })
    }

    /// Records the calls a stubbed labels.patch receives.
    final class PatchRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(String, GmailLabelColor?)] = []
        var calls: [(String, GmailLabelColor?)] { lock.withLock { seen } }
        func record(_ id: String, _ color: GmailLabelColor?) { lock.withLock { seen.append((id, color)) } }
    }

    private let blue = GmailLabelColor(background: "#4a86e8", text: "#ffffff")!
    private let yellow = LabelColors(background: "#fad165", text: "#000000")

    // MARK: - Palette

    /// The frozen set matches the API reference list kept independently in
    /// LabelColorStyleTests, value for value.
    func testAllowedSetIsGmailsReferenceList() {
        XCTAssertEqual(GmailLabelPalette.allowedHex, LabelColorStyleTests.gmailPalette)
        XCTAssertEqual(GmailLabelPalette.allowed.count, 102)
    }

    /// Every offered swatch is a pair the API accepts, the grid has no
    /// duplicates and fills whole rows, and its text is readable as the
    /// pill draws it: the pair's own text color, at WCAG AA.
    func testEverySwatchIsValidAndReadable() {
        let swatches = GmailLabelPalette.swatches
        XCTAssertEqual(swatches.count, 64)
        XCTAssertEqual(swatches.count % GmailLabelPalette.columns, 0)
        XCTAssertEqual(Set(swatches.map(\.background)).count, swatches.count)
        for s in swatches {
            XCTAssertTrue(GmailLabelPalette.allowed.contains(s.background), s.background)
            XCTAssertTrue(GmailLabelPalette.allowed.contains(s.text), s.text)
            XCTAssertEqual(GmailLabelColor(background: s.background, text: s.text), s)
            let fill = LabelRGB(hexString: s.background)!
            let text = LabelRGB(hexString: s.text)!
            XCTAssertGreaterThanOrEqual(text.contrast(with: fill), LabelPillStyle.minimumTextContrast, s.background)
            for appearance in LabelPillStyle.Appearance.allCases {
                let style = LabelPillStyle.resolve(s.colors, appearance: appearance)
                XCTAssertEqual(style.fill, fill)
                XCTAssertEqual(style.text, text, "own text color kept on \(s.background)")
            }
        }
    }

    func testOffPaletteColorsAreRefused() {
        XCTAssertNotNil(GmailLabelColor(background: " #4A86E8", text: "FFFFFF"))
        for (bg, text) in [("#4a86e9", "#ffffff"), ("#4a86e8", "#fffffe"), ("#EB5757", "#000000"),
                           ("red", "#000000"), ("", "#000000")] as [(String?, String?)]
            + [(nil, "#000000"), ("#4a86e8", nil)] {
            XCTAssertNil(GmailLabelColor(background: bg, text: text), "\(String(describing: bg)) / \(String(describing: text))")
        }
        // The Mac-only palette is not Gmail's: none of it may be sent.
        for swatch in ["#EB5757", "#F2994A", "#DFAB01", "#27AE60", "#12A594", "#2D9CDB",
                       "#5E6AD2", "#9B51E0", "#E255A1", "#9F6B53", "#787774"] {
            XCTAssertNil(GmailLabelColor(background: swatch, text: "#000000"), swatch)
        }
    }

    // MARK: - Request body

    func testPatchBodySendsOnlyTheColor() throws {
        let body = GmailClient.labelColorPatchBody(blue)
        XCTAssertEqual(Array(body.keys), ["color"])
        let color = try XCTUnwrap(body["color"] as? [String: String])
        XCTAssertEqual(color, ["backgroundColor": "#4a86e8", "textColor": "#ffffff"])
        let removal = GmailClient.labelColorPatchBody(nil)
        XCTAssertEqual(Array(removal.keys), ["color"])
        XCTAssertTrue(removal["color"] is NSNull)
        let json = try JSONSerialization.data(withJSONObject: removal)
        XCTAssertEqual(String(data: json, encoding: .utf8), #"{"color":null}"#)
    }

    func testPatchHasTheLabelsQuotaCost() {
        XCTAssertEqual(GmailClient.quotaCost(method: "PATCH", path: "/labels/Label_1"), 5)
    }

    // MARK: - Edit flow (stubbed labels.patch)

    func testSuccessfulPatchStoresGmailsAnswer() async throws {
        let q = try makeDB(gmail: yellow)
        let pending = PendingLabelColorEdits()
        let calls = PatchRecorder()
        try await GmailLabelColorEdit.apply(blue, labelRowId: rowId, db: q, pending: pending) { id, color in
            calls.record(id, color)
            return self.answer(LabelColors(background: "#4A86E8", text: "#FFFFFF"))
        }
        XCTAssertEqual(calls.calls.map { $0.0 }, ["Label_1"])
        XCTAssertEqual(calls.calls.first?.1, blue)
        XCTAssertEqual(try gmailColors(q), blue.colors)
        XCTAssertNil(try row(q).color, "the Mac-only color is untouched")
    }

    /// The new color is stored, and the app told to show it, before Gmail
    /// is called.
    func testUpdateIsShownBeforeGmailAnswers() async throws {
        let q = try makeDB(gmail: yellow)
        let id = rowId
        var shown: LabelRow?
        var patchedAfterShown = false
        try await GmailLabelColorEdit.apply(blue, labelRowId: id, db: q,
                                            pending: PendingLabelColorEdits(),
                                            didStore: { shown = try? await q.read { db in try LabelRow.fetchOne(db, key: id) } }) { _, _ in
            patchedAfterShown = shown != nil
            return self.answer(self.blue.colors)
        }
        XCTAssertEqual(shown?.gmailBackgroundColor, "#4a86e8")
        XCTAssertEqual(shown?.gmailTextColor, "#ffffff")
        XCTAssertTrue(patchedAfterShown)
    }

    func testFailedPatchRestoresThePreviousColor() async throws {
        let q = try makeDB(gmail: yellow)
        let pending = PendingLabelColorEdits()
        do {
            try await GmailLabelColorEdit.apply(blue, labelRowId: rowId, db: q, pending: pending) { _, _ in
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("no error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertEqual(try gmailColors(q), yellow)
        // Nothing held: the next sync's answer is stored as is.
        XCTAssertNil(pending.held(rowId, fetched: yellow, now: Date()))
    }

    func testScopeRefusalRestoresAndAsksToReauthorize() async throws {
        let q = try makeDB(gmail: yellow)
        let body = #"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","#
            + #""errors":[{"reason":"insufficientPermissions"}]}}"#
        do {
            try await GmailLabelColorEdit.apply(nil, labelRowId: rowId, db: q,
                                                pending: PendingLabelColorEdits()) { _, _ in
                throw GmailError.http(403, body)
            }
            XCTFail("no error")
        } catch {
            XCTAssertEqual(GmailLabelColorEdit.outcome(error, accountKnown: true), .reauthorize)
        }
        XCTAssertEqual(try gmailColors(q), yellow)
    }

    func testOutcomes() {
        let rate = GmailError.http(403, #"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#)
        guard case .banner(let text) = GmailLabelColorEdit.outcome(rate, accountKnown: true) else {
            return XCTFail("a 403 rate limit is not a scope problem")
        }
        XCTAssertFalse(text.isEmpty)
        XCTAssertEqual(GmailLabelColorEdit.outcome(nil, accountKnown: true), .saved)
        XCTAssertEqual(GmailLabelColorEdit.outcome(GmailLabelColorEdit.Failure.notApplied, accountKnown: true),
                       .banner("Gmail didn't apply the color change."))
        // An account removed meanwhile gets no banner and no reauth request.
        XCTAssertEqual(GmailLabelColorEdit.outcome(GmailError.http(403, "{}"), accountKnown: false), .silent)
        XCTAssertEqual(GmailLabelColorEdit.outcome(URLError(.timedOut), accountKnown: false), .silent)
    }

    func testSystemLabelIsRefusedBeforeTheCall() async throws {
        let q = try makeDB(type: "system", gmailId: "INBOX")
        let calls = PatchRecorder()
        do {
            try await GmailLabelColorEdit.apply(blue, labelRowId: "\(account):INBOX", db: q,
                                                pending: PendingLabelColorEdits()) { id, color in
                calls.record(id, color)
                return self.answer(self.blue.colors, id: "INBOX")
            }
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error as? GmailLabelColorEdit.Failure, .systemLabel)
        }
        XCTAssertTrue(calls.calls.isEmpty)
        XCTAssertNil(try row(q, "\(account):INBOX").gmailBackgroundColor)
    }

    /// Removing the color on Gmail leaves the label neutral grey.
    func testRemovingTheColorShowsNeutralGrey() async throws {
        let q = try makeDB(gmail: yellow)
        let calls = PatchRecorder()
        try await GmailLabelColorEdit.apply(nil, labelRowId: rowId, db: q,
                                            pending: PendingLabelColorEdits()) { id, color in
            calls.record(id, color)
            return self.answer(nil)
        }
        XCTAssertEqual(calls.calls.count, 1)
        XCTAssertNil(calls.calls.first?.1)
        XCTAssertEqual(try row(q).displayColors, .none)
        let style = LabelPillStyle.resolve(try row(q).displayColors, appearance: .light)
        XCTAssertEqual(style.fill, LabelPillStyle.neutralFill(.light))
    }

    /// Gmail answers 200 but keeps another color: its answer is stored and
    /// the user is told.
    func testColorGmailDidNotApplyIsReported() async throws {
        let q = try makeDB(gmail: yellow)
        do {
            try await GmailLabelColorEdit.apply(nil, labelRowId: rowId, db: q,
                                                pending: PendingLabelColorEdits()) { _, _ in
                self.answer(self.yellow)
            }
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error as? GmailLabelColorEdit.Failure, .notApplied)
        }
        XCTAssertEqual(try gmailColors(q), yellow)
    }

    func testSecondEditWhileOneIsInFlightIsRefused() async throws {
        let q = try makeDB(gmail: yellow)
        let pending = PendingLabelColorEdits()
        try await GmailLabelColorEdit.apply(blue, labelRowId: rowId, db: q, pending: pending) { _, _ in
            do {
                try await GmailLabelColorEdit.apply(nil, labelRowId: self.rowId, db: q, pending: pending) { _, _ in
                    XCTFail("second call reached Gmail")
                    return self.answer(nil)
                }
                XCTFail("no error")
            } catch {
                XCTAssertEqual(error as? GmailLabelColorEdit.Failure, .inFlight)
            }
            return self.answer(self.blue.colors)
        }
        XCTAssertEqual(try gmailColors(q), blue.colors)
    }

    // MARK: - No bounce from a sync

    private func sync(_ q: DatabaseQueue, _ colors: LabelColors?, pending: PendingLabelColorEdits,
                      now: Date = Date()) throws {
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [answer(colors)],
                                       pendingColors: pending, now: now)
        }
    }

    /// A sync whose list Gmail sent before the patch landed, applied while
    /// the patch is in flight and again after it, does not put the old
    /// color back.
    func testStaleSyncDoesNotBounceTheColor() async throws {
        let q = try makeDB(gmail: yellow)
        let pending = PendingLabelColorEdits()
        let start = Date()
        try await GmailLabelColorEdit.apply(blue, labelRowId: rowId, db: q, pending: pending,
                                            now: { start }) { _, _ in
            try self.sync(q, self.yellow, pending: pending, now: start)
            XCTAssertEqual(try self.gmailColors(q), self.blue.colors, "during the patch")
            return self.answer(self.blue.colors)
        }
        try sync(q, yellow, pending: pending, now: start.addingTimeInterval(5))
        XCTAssertEqual(try gmailColors(q), blue.colors, "after the patch")
    }

    /// Once Gmail agrees, or the grace period is over, the sync rules again:
    /// a later change made in Gmail shows.
    func testSyncFollowsGmailAgainAfterAgreementOrExpiry() async throws {
        let q = try makeDB(gmail: yellow)
        let pending = PendingLabelColorEdits()
        let start = Date()
        try await GmailLabelColorEdit.apply(blue, labelRowId: rowId, db: q, pending: pending,
                                            now: { start }) { _, _ in self.answer(self.blue.colors) }
        try sync(q, blue.colors, pending: pending, now: start.addingTimeInterval(1))
        try sync(q, yellow, pending: pending, now: start.addingTimeInterval(2))
        XCTAssertEqual(try gmailColors(q), yellow, "changed in Gmail after the edit was seen")

        try await GmailLabelColorEdit.apply(blue, labelRowId: rowId, db: q, pending: pending,
                                            now: { start }) { _, _ in self.answer(self.blue.colors) }
        try sync(q, yellow, pending: pending,
                 now: start.addingTimeInterval(PendingLabelColorEdits.grace + 1))
        XCTAssertEqual(try gmailColors(q), yellow, "held no longer than the grace period")
    }

    func testRemovedAccountLeavesNothingHeld() {
        let pending = PendingLabelColorEdits()
        XCTAssertTrue(pending.begin("\(account):Label_1", colors: blue.colors))
        XCTAssertTrue(pending.begin("b@x.com:Label_1", colors: blue.colors))
        pending.forgetAccount(account)
        XCTAssertNil(pending.held("\(account):Label_1", fetched: yellow, now: Date()))
        XCTAssertEqual(pending.held("b@x.com:Label_1", fetched: yellow, now: Date()), blue.colors)
    }

    /// Removing the account while its edit is in flight: the late answer
    /// puts nothing back in memory.
    func testRemovalDuringAnEditLeavesNothingHeld() async throws {
        let q = try makeDB(gmail: yellow)
        let pending = PendingLabelColorEdits()
        try await GmailLabelColorEdit.apply(blue, labelRowId: rowId, db: q, pending: pending) { _, _ in
            pending.forgetAccount(self.account)
            return self.answer(self.blue.colors)
        }
        XCTAssertNil(pending.held(rowId, fetched: yellow, now: Date()))
    }

    /// A second edit that fails does not drop the hold of a first one
    /// Gmail confirmed: a stale sync still cannot bring the old color back.
    func testFailedSecondEditKeepsTheFirstHold() async throws {
        let q = try makeDB(gmail: yellow)
        let pending = PendingLabelColorEdits()
        let start = Date()
        try await GmailLabelColorEdit.apply(blue, labelRowId: rowId, db: q, pending: pending,
                                            now: { start }) { _, _ in self.answer(self.blue.colors) }
        do {
            try await GmailLabelColorEdit.apply(nil, labelRowId: rowId, db: q, pending: pending) { _, _ in
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("no error")
        } catch {}
        XCTAssertEqual(try gmailColors(q), blue.colors, "restored to the confirmed color")
        try sync(q, yellow, pending: pending, now: start.addingTimeInterval(5))
        XCTAssertEqual(try gmailColors(q), blue.colors, "hold kept")
    }

    /// The restore after a failure only replaces the app's own write: a
    /// sync that stored newer colors meanwhile wins.
    func testRestoreDoesNotOverwriteNewerColors() async throws {
        let q = try makeDB(gmail: yellow)
        let id = rowId
        do {
            try await GmailLabelColorEdit.apply(blue, labelRowId: id, db: q,
                                                pending: PendingLabelColorEdits()) { _, _ in
                try await q.write { db in
                    try db.execute(sql: "UPDATE label SET gmailBackgroundColor = '#16a766', gmailTextColor = '#ffffff' WHERE id = ?",
                                   arguments: [id])
                }
                throw URLError(.timedOut)
            }
            XCTFail("no error")
        } catch {}
        XCTAssertEqual(try gmailColors(q), LabelColors(background: "#16a766", text: "#ffffff"))
    }

    /// labels.patch answers with the label resource; its color decodes.
    func testPatchAnswerDecodes() throws {
        let json = Data(##"{"id":"Label_1","name":"Work","type":"user","color":{"textColor":"#ffffff","backgroundColor":"#4a86e8"}}"##.utf8)
        let label = try JSONDecoder().decode(GLabel.self, from: json)
        XCTAssertEqual(GmailLabelColorEdit.colors(of: label), blue.colors)
        let bare = try JSONDecoder().decode(GLabel.self, from: Data(#"{"id":"Label_1","name":"Work"}"#.utf8))
        XCTAssertEqual(GmailLabelColorEdit.colors(of: bare), .none)
    }

    func testLabelIdIsOnePathSegment() {
        XCTAssertEqual(GmailClient.pathSegment("Label_12"), "Label_12")
        XCTAssertEqual(GmailClient.pathSegment("../filters?x=1#y"), "..%2Ffilters%3Fx%3D1%23y")
        // Filter ids share the helper; non-ASCII letters are encoded too.
        XCTAssertEqual(GmailClient.pathSegment("ANe1Bm-x_y"), "ANe1Bm-x_y")
        XCTAssertEqual(GmailClient.pathSegment("é"), "%C3%A9")
    }

    // MARK: - Mac-only color precedence (DEC-023)

    /// A Mac-only color still wins after a Gmail edit and a sync, and is
    /// never sent; clearing it shows the color on Gmail.
    func testMacOnlyColorWinsOverTheGmailColor() async throws {
        let q = try makeDB(gmail: yellow)
        let id = rowId
        try await q.write { db in
            try db.execute(sql: "UPDATE label SET color = '#EB5757' WHERE id = ?", arguments: [id])
        }
        let calls = PatchRecorder()
        try await GmailLabelColorEdit.apply(blue, labelRowId: rowId, db: q,
                                            pending: PendingLabelColorEdits()) { id, color in
            calls.record(id, color)
            return self.answer(self.blue.colors)
        }
        XCTAssertEqual(calls.calls.first?.1, blue, "only the Gmail color is sent")
        try sync(q, blue.colors, pending: PendingLabelColorEdits())
        XCTAssertEqual(try row(q).color, "#EB5757")
        XCTAssertEqual(try row(q).displayColors.background, "#EB5757")
        try await q.write { db in
            try db.execute(sql: "UPDATE label SET color = NULL WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(try row(q).displayColors, blue.colors)
    }
}
