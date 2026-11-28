import XCTest
import GRDB

/// Gmail's `colorPreset` next to `color`: decoded as sent, stored (v71),
/// and used to draw a label
/// whose `color` is absent or the neutral #eeeeee / #222222 pair.
final class LabelColorPresetTests: XCTestCase {
    private let account = "a@example.com"
    private var rowId: String { "\(account):Label_1" }
    private let fallback = LabelColors(background: "#eeeeee", text: "#222222")
    private let darkGreen = LabelColors(background: "#076239", text: "#ffffff")

    private func decode(_ json: String) throws -> GLabel {
        try JSONDecoder().decode(GLabel.self, from: Data(json.utf8))
    }

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
        }
        return q
    }

    private func stored(_ q: DatabaseQueue) throws -> LabelRow {
        try XCTUnwrap(try q.read { db in try LabelRow.fetchOne(db, key: rowId) })
    }

    private func label(_ colors: LabelColors?, preset: String?) -> GLabel {
        GLabel(id: "Label_1", name: "Project", type: "user",
               color: colors.map { GLabel.GColor(backgroundColor: $0.background, textColor: $0.text) },
               colorPreset: preset)
    }

    private func row(_ colors: LabelColors = .none, preset: String? = nil, local: String? = nil,
                     readInFull: Bool = false) -> LabelRow {
        LabelRow(id: "a:L", accountId: "a", gmailLabelId: "L", name: "n", type: "user",
                 color: local, gmailBackgroundColor: colors.background,
                 gmailTextColor: colors.text, gmailColorPreset: preset,
                 gmailColorReadInFull: readInFull)
    }

    private func sync(_ q: DatabaseQueue, _ labels: [GLabel], readInFull: Set<String> = [],
                      pending: PendingLabelColorEdits = PendingLabelColorEdits()) throws {
        let account = self.account
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: labels,
                                       readInFull: readInFull, pendingColors: pending)
        }
    }

    // MARK: - Decoding

    func testDecodesPresetWithColor() throws {
        let l = try decode("""
            {"id":"Label_1","name":"Project","type":"user",
             "color":{"backgroundColor":"#076239","textColor":"#ffffff"},
             "colorPreset":"LABEL_COLOR_PRESET_DARK_GREEN"}
            """)
        XCTAssertEqual(l.colorPreset, "LABEL_COLOR_PRESET_DARK_GREEN")
        XCTAssertEqual(l.color?.backgroundColor, "#076239")
    }

    func testDecodesPresetWithoutColor() throws {
        let l = try decode(#"{"id":"Label_1","name":"Project","colorPreset":"LABEL_COLOR_PRESET_TEAL"}"#)
        XCTAssertEqual(l.colorPreset, "LABEL_COLOR_PRESET_TEAL")
        XCTAssertNil(l.color)
    }

    func testDecodesAnUnknownPresetAsSent() throws {
        let l = try decode(#"{"id":"Label_1","name":"Project","colorPreset":"LABEL_COLOR_PRESET_NEW_HUE"}"#)
        XCTAssertEqual(l.colorPreset, "LABEL_COLOR_PRESET_NEW_HUE")
    }

    func testDecodesNeitherColorNorPreset() throws {
        let l = try decode(#"{"id":"Label_1","name":"Project","type":"user"}"#)
        XCTAssertNil(l.colorPreset)
        XCTAssertNil(l.color)
    }

    // MARK: - Storage and migration

    func testMigrationV71AddsTheColumnAndKeepsRows() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v70")
        try q.write { db in
            try db.execute(sql: "INSERT INTO account (id, displayName, senderName) VALUES (?, 'P', '')",
                           arguments: [account])
            try db.execute(sql: """
                INSERT INTO label (id, accountId, gmailLabelId, name, type, sortOrder,
                                   gmailBackgroundColor, gmailTextColor)
                VALUES (?, ?, 'Label_1', 'Project', 'user', ?, '#eeeeee', '#222222')
                """, arguments: [rowId, account, LabelRow.unsorted])
        }
        try AppDatabase.migrator.migrate(q)
        try q.read { db in
            let columns = try db.columns(in: "label").map(\.name)
            XCTAssertTrue(columns.contains("gmailColorPreset"))
            XCTAssertTrue(columns.contains("gmailColorReadInFull"))
        }
        let r = try stored(q)
        XCTAssertNil(r.gmailColorPreset)
        XCTAssertFalse(r.gmailColorReadInFull)
        XCTAssertEqual(r.gmailBackgroundColor, "#eeeeee")
    }

    func testSyncStoresRefreshesAndClearsThePreset() throws {
        let q = try makeDB()
        try sync(q, [label(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN")])
        XCTAssertEqual(try stored(q).gmailColorPreset, "LABEL_COLOR_PRESET_DARK_GREEN")
        XCTAssertEqual(try stored(q).gmailBackgroundColor, "#eeeeee", "color is stored as sent")
        try sync(q, [label(fallback, preset: "LABEL_COLOR_PRESET_NEW_HUE")])
        XCTAssertEqual(try stored(q).gmailColorPreset, "LABEL_COLOR_PRESET_NEW_HUE")
        // A real color in the list contradicts the stored preset.
        try sync(q, [label(LabelColors(background: "#fad165", text: "#000000"), preset: nil)])
        XCTAssertNil(try stored(q).gmailColorPreset)
    }

    /// Which listed labels are read in full: no background, or the neutral
    /// pair without a preset. A real color or a listed preset is not.
    func testWhichLabelsAreReadInFull() {
        XCTAssertTrue(GmailLabelColorPreset.wantsFullRead(label(nil, preset: nil)))
        XCTAssertTrue(GmailLabelColorPreset.wantsFullRead(label(fallback, preset: nil)))
        XCTAssertTrue(GmailLabelColorPreset.wantsFullRead(
            label(LabelColors(background: "#EEEEEE", text: "#222222"), preset: "")))
        XCTAssertFalse(GmailLabelColorPreset.wantsFullRead(
            label(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN")))
        XCTAssertFalse(GmailLabelColorPreset.wantsFullRead(label(darkGreen, preset: nil)))
        XCTAssertFalse(GmailLabelColorPreset.wantsFullRead(
            label(LabelColors(background: "#eeeeee", text: "#000000"), preset: nil)))
    }

    /// A color write stores Gmail's answer, not a full read: the next sync
    /// reads that label in full again, inside the recheck interval too.
    func testColorWriteMakesTheNextSyncReadTheLabelInFull() async throws {
        let q = try makeDB()
        try sync(q, [label(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN")], readInFull: ["Label_1"])
        let now = Date()
        let checked = ["Label_1": now]
        let listed = [label(fallback, preset: nil)]
        XCTAssertTrue(SyncEngine.fullReadsDue(listed, checkedAt: checked, notReadInFull: [], now: now)
            .isEmpty, "read in full a moment ago")
        try await GmailLabelColorEdit.apply(nil, labelRowId: rowId, db: q,
                                            pending: PendingLabelColorEdits()) { _, _ in
            self.label(nil, preset: nil)
        }
        XCTAssertFalse(try stored(q).gmailColorReadInFull)
        let notRead = try await q.read { db in
            try String.fetchSet(db, sql: "SELECT gmailLabelId FROM label WHERE gmailColorReadInFull = 0")
        }
        XCTAssertEqual(SyncEngine.fullReadsDue(listed, checkedAt: checked, notReadInFull: notRead, now: now),
                       ["Label_1"])
        // Still only labels the list leaves uncolored, and only user labels.
        XCTAssertTrue(SyncEngine.fullReadsDue([label(darkGreen, preset: nil)], checkedAt: checked,
                                              notReadInFull: notRead, now: now).isEmpty)
        XCTAssertEqual(SyncEngine.fullReadsDue(listed, checkedAt: checked, notReadInFull: [],
                                               now: now + SyncEngine.colorRecheck), ["Label_1"])
    }

    /// A preset learned from the full read stays while later lists send no
    /// preset and no color other than the neutral pair (or none); a listed
    /// preset or a real color replaces it.
    func testPresetFromTheFullReadIsKeptWhileTheListSaysNothing() throws {
        let q = try makeDB()
        try sync(q, [label(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN")], readInFull: ["Label_1"])
        XCTAssertTrue(try stored(q).gmailColorReadInFull)
        try sync(q, [label(fallback, preset: nil)])
        XCTAssertEqual(try stored(q).gmailColorPreset, "LABEL_COLOR_PRESET_DARK_GREEN")
        XCTAssertTrue(try stored(q).gmailColorReadInFull)
        XCTAssertEqual(try stored(q).displayColors, darkGreen)
        try sync(q, [label(nil, preset: nil)])
        XCTAssertEqual(try stored(q).gmailColorPreset, "LABEL_COLOR_PRESET_DARK_GREEN",
                       "no color in the list is no contradiction")
        try sync(q, [label(fallback, preset: "LABEL_COLOR_PRESET_")])
        XCTAssertEqual(try stored(q).gmailColorPreset, "LABEL_COLOR_PRESET_DARK_GREEN",
                       "the bare prefix says nothing")
        try sync(q, [label(fallback, preset: "LABEL_COLOR_PRESET_TEAL")])
        XCTAssertEqual(try stored(q).gmailColorPreset, "LABEL_COLOR_PRESET_TEAL")
        XCTAssertFalse(try stored(q).gmailColorReadInFull, "the list's own preset")
        try sync(q, [label(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN")], readInFull: ["Label_1"])
        try sync(q, [label(darkGreen, preset: nil)])
        XCTAssertNil(try stored(q).gmailColorPreset, "a real color contradicts it")
        XCTAssertFalse(try stored(q).gmailColorReadInFull)
    }

    /// A full read that sends no preset is recorded as such, and is
    /// authoritative over a stored one.
    func testFullReadWithoutPresetClearsAndIsRecorded() throws {
        let q = try makeDB()
        try sync(q, [label(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN")], readInFull: ["Label_1"])
        try sync(q, [label(fallback, preset: nil)], readInFull: ["Label_1"])
        XCTAssertNil(try stored(q).gmailColorPreset)
        XCTAssertTrue(try stored(q).gmailColorReadInFull)
        XCTAssertEqual(try stored(q).displayColors, fallback)
    }

    /// The list and the full read are merged: the full read's preset wins,
    /// and the list's is kept when the full read has none.
    func testCompletingColorsCarriesThePreset() async throws {
        let listed = [GLabel(id: "L1", name: "a", type: "user", color: nil),
                      GLabel(id: "L2", name: "b", type: "user", color: nil,
                             colorPreset: "LABEL_COLOR_PRESET_RED")]
        let out = try await SyncEngine.completingColors(listed, ids: ["L1", "L2"]) { id in
            id == "L1"
                ? GLabel(id: id, name: "a", type: "user", color: nil, colorPreset: "LABEL_COLOR_PRESET_BLUE")
                : GLabel(id: id, name: "b", type: "user", color: nil)
        }
        XCTAssertEqual(out.labels.map(\.colorPreset), ["LABEL_COLOR_PRESET_BLUE", "LABEL_COLOR_PRESET_RED"])
    }

    // MARK: - Writing a color

    /// While a color edit is pending, an older sync answer brings back
    /// neither the old colors nor the old preset.
    func testPendingRemovalKeepsTheOldPresetAway() async throws {
        let q = try makeDB()
        try sync(q, [label(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN")], readInFull: ["Label_1"])
        let pending = PendingLabelColorEdits()
        let old = [label(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN")]
        let account = self.account
        try await GmailLabelColorEdit.apply(nil, labelRowId: rowId, db: q, pending: pending) { _, _ in
            // A sync lands while the call is in flight, with the old answer.
            try await q.write { db in
                try SyncEngine.applyLabels(db, accountId: account, labels: old,
                                           readInFull: ["Label_1"], pendingColors: pending)
            }
            return self.label(nil, preset: nil)
        }
        XCTAssertNil(try stored(q).gmailColorPreset)
        XCTAssertEqual(try stored(q).displayColors, .none)
        // And once more within the hold, after Gmail's answer.
        try sync(q, old, readInFull: ["Label_1"], pending: pending)
        XCTAssertNil(try stored(q).gmailColorPreset)
        XCTAssertEqual(try stored(q).displayColors, .none)
    }

    /// The removal is shown at once: the preset goes with the colors.
    func testRemovalClearsThePresetBeforeGmailAnswers() async throws {
        let q = try makeDB()
        try sync(q, [label(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN")])
        try await GmailLabelColorEdit.apply(nil, labelRowId: rowId, db: q,
                                            pending: PendingLabelColorEdits()) { _, _ in
            XCTAssertEqual(try self.stored(q).displayColors, .none, "shown before the answer")
            return self.label(nil, preset: nil)
        }
    }

    /// A failed removal puts the preset back with the colors.
    func testFailedRemovalRestoresThePreset() async throws {
        let q = try makeDB()
        try sync(q, [label(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN")])
        do {
            try await GmailLabelColorEdit.apply(nil, labelRowId: rowId, db: q,
                                                pending: PendingLabelColorEdits()) { _, _ in
                throw GmailError.http(500, "")
            }
            XCTFail("the error is rethrown")
        } catch GmailError.http(500, _) {}
        XCTAssertEqual(try stored(q).gmailColorPreset, "LABEL_COLOR_PRESET_DARK_GREEN")
        XCTAssertEqual(try stored(q).displayColors, darkGreen)
    }

    /// "Remove color" is offered whenever the label is drawn with a Gmail
    /// color: a pair, the neutral pair, or a known preset alone.
    func testRemoveIsOfferedWhenDrawnWithAGmailColor() {
        XCTAssertTrue(row(darkGreen).hasGmailColor)
        XCTAssertTrue(row(fallback).hasGmailColor)
        XCTAssertTrue(row(preset: "LABEL_COLOR_PRESET_RED").hasGmailColor)
        XCTAssertFalse(row(preset: "LABEL_COLOR_PRESET_NEW_HUE").hasGmailColor)
        XCTAssertFalse(row().hasGmailColor)
        XCTAssertFalse(row(local: "#eb5757").hasGmailColor, "the Mac-only color is not Gmail's")
    }

    /// A removal Gmail answers with no color but a known preset leaves the
    /// label colored: an error, not success.
    func testRemovalAnsweredWithAPresetIsAnError() async throws {
        let q = try makeDB()
        try sync(q, [label(nil, preset: "LABEL_COLOR_PRESET_RED")])
        do {
            try await GmailLabelColorEdit.apply(nil, labelRowId: rowId, db: q,
                                                pending: PendingLabelColorEdits()) { _, _ in
                self.label(nil, preset: "LABEL_COLOR_PRESET_RED")
            }
            XCTFail("a kept preset is reported")
        } catch let failure as GmailLabelColorEdit.Failure {
            XCTAssertEqual(failure, .presetKept)
        }
        XCTAssertEqual(try stored(q).gmailColorPreset, "LABEL_COLOR_PRESET_RED", "what Gmail answered")
        XCTAssertTrue(try stored(q).hasGmailColor)
        XCTAssertEqual(GmailLabelColorEdit.outcome(GmailLabelColorEdit.Failure.presetKept, accountKnown: true),
                       .banner(GmailLabelColorEdit.Failure.presetKept.errorDescription ?? ""))
        // An unknown preset does not color the label: success.
        try await GmailLabelColorEdit.apply(nil, labelRowId: rowId, db: q,
                                            pending: PendingLabelColorEdits()) { _, _ in
            self.label(nil, preset: "LABEL_COLOR_PRESET_NEW_HUE")
        }
    }

    func testCascadeRemovalAnsweredWithAPresetFails() async throws {
        let q = try makeDB()
        try sync(q, [label(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN")])
        let result = await GmailLabelColorEdit.applyMany(nil, labelRowIds: [rowId], db: q,
                                                         pending: PendingLabelColorEdits()) { _, _ in
            self.label(nil, preset: "LABEL_COLOR_PRESET_DARK_GREEN")
        }
        XCTAssertEqual(result.failed, [rowId])
        XCTAssertEqual(result.cause as? GmailLabelColorEdit.Failure, .presetKept)
        XCTAssertEqual(result.permanent, [rowId], "a retry gets the same answer")
        XCTAssertTrue(result.retryable.isEmpty)
    }

    // MARK: - New labels

    /// A sublabel starts with the color its parent is drawn with (DEC-071):
    /// the preset's pair when the stored one is neutral.
    func testSublabelTakesTheParentsDrawnColor() {
        XCTAssertEqual(row(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN").inheritableGmailColor,
                       GmailLabelColor(background: "#076239", text: "#ffffff"))
        XCTAssertEqual(row(preset: "LABEL_COLOR_PRESET_YELLOW").inheritableGmailColor,
                       GmailLabelColor(background: "#fad165", text: "#000000"))
        XCTAssertNil(row(fallback).inheritableGmailColor, "the neutral pair is not in the palette")
        XCTAssertEqual(row(LabelColors(background: "#4a86e8", text: "#ffffff")).inheritableGmailColor,
                       GmailLabelColor(background: "#4a86e8", text: "#ffffff"))
    }

    func testCreatedRowCarriesThePresetOfTheAnswer() {
        let created = LabelRow.created(label(fallback, preset: "LABEL_COLOR_PRESET_MINT"), accountId: account)
        XCTAssertEqual(created.gmailColorPreset, "LABEL_COLOR_PRESET_MINT")
        XCTAssertNil(LabelRow.created(label(nil, preset: nil), accountId: account).gmailColorPreset)
    }

    /// A write keeps the preset Gmail's answer carries, and clears a stored
    /// one when the answer has none: no stale preset stays behind.
    func testColorWriteStoresThePresetOfGmailsAnswer() async throws {
        let q = try makeDB()
        let account = self.account
        let synced = [label(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN")]
        try await q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: synced)
        }
        let blue = try XCTUnwrap(GmailLabelColor(background: "#4a86e8", text: "#ffffff"))
        try await GmailLabelColorEdit.apply(blue, labelRowId: rowId, db: q,
                                            pending: PendingLabelColorEdits()) { _, _ in
            self.label(blue.colors, preset: nil)
        }
        XCTAssertNil(try stored(q).gmailColorPreset)
        XCTAssertEqual(try stored(q).displayColors, blue.colors)

        try await GmailLabelColorEdit.apply(blue, labelRowId: rowId, db: q,
                                            pending: PendingLabelColorEdits()) { _, _ in
            self.label(blue.colors, preset: "LABEL_COLOR_PRESET_BLUE")
        }
        XCTAssertEqual(try stored(q).gmailColorPreset, "LABEL_COLOR_PRESET_BLUE")
    }

    func testCascadeWriteStoresThePresetOfGmailsAnswer() async throws {
        let q = try makeDB()
        let account = self.account
        let synced = [label(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN")]
        try await q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: synced)
        }
        let result = await GmailLabelColorEdit.applyMany(nil, labelRowIds: [rowId], db: q,
                                                         pending: PendingLabelColorEdits()) { _, _ in
            self.label(nil, preset: nil)
        }
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertNil(try stored(q).gmailColorPreset)
        XCTAssertEqual(try stored(q).displayColors, .none)
    }

    /// A preset name that is not plain (newline, bidi control) is stored as sent.
    func testOddPresetIsStoredAsSent() throws {
        let q = try makeDB()
        let odd = "LABEL_COLOR_PRESET_RED\u{202E}X"
        try sync(q, [label(nil, preset: odd)])
        XCTAssertEqual(try stored(q).gmailColorPreset, odd, "stored as sent")
        XCTAssertEqual(try stored(q).displayColors, .none, "an unknown preset draws nothing")
    }

    // MARK: - Drawing

    func testFallbackWithAKnownPresetIsDrawnByThePreset() {
        XCTAssertEqual(row(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN").displayColors, darkGreen)
        XCTAssertEqual(row(LabelColors(background: "#EEEEEE", text: "#222222"),
                           preset: "LABEL_COLOR_PRESET_DARK_GREEN").displayColors, darkGreen,
                       "case does not matter")
    }

    func testNoColorWithAKnownPresetIsDrawnByThePreset() {
        XCTAssertEqual(row(preset: "LABEL_COLOR_PRESET_GREEN").displayColors,
                       LabelColors(background: "#16a765", text: "#ffffff"))
    }

    /// A real color is drawn as it is, whatever the preset says.
    func testARealColorWinsOverThePreset() {
        let yellow = LabelColors(background: "#fad165", text: "#000000")
        XCTAssertEqual(row(yellow, preset: "LABEL_COLOR_PRESET_DARK_GREEN").displayColors, yellow)
        // Only the exact pair is the fallback: #eeeeee with another text is a color.
        let grey = LabelColors(background: "#eeeeee", text: "#000000")
        XCTAssertEqual(row(grey, preset: "LABEL_COLOR_PRESET_DARK_GREEN").displayColors, grey)
    }

    func testUnchangedWithoutAKnownPreset() {
        XCTAssertEqual(row(fallback).displayColors, fallback, "fallback without preset: as today")
        XCTAssertEqual(row(fallback, preset: "LABEL_COLOR_PRESET_NEW_HUE").displayColors, fallback)
        XCTAssertEqual(row(fallback, preset: "LABEL_COLOR_PRESET_UNSPECIFIED").displayColors, fallback)
        XCTAssertEqual(row(preset: "LABEL_COLOR_PRESET_NEW_HUE").displayColors, .none)
        XCTAssertEqual(row().displayColors, .none)
    }

    /// The Mac-only color is ignored: the preset draws.
    func testLocalPickIsIgnoredWithAPreset() {
        XCTAssertEqual(row(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN", local: "#EB5757").displayColors,
                       darkGreen)
    }

    /// The 21 presets Google lists, each a pair Gmail accepts, each drawn as
    /// a visible fill (never the "no color" outline) in both appearances.
    func testEveryMappedPresetIsAVisibleFillInBothAppearances() throws {
        XCTAssertEqual(GmailLabelColorPreset.colors.count, 21)
        for (name, color) in GmailLabelColorPreset.colors {
            XCTAssertTrue(GmailLabelPalette.allowed.contains(color.background), name)
            XCTAssertTrue(GmailLabelPalette.allowed.contains(color.text), name)
            let colors = row(fallback, preset: GmailLabelColorPreset.prefix + name).displayColors
            XCTAssertEqual(colors, color.colors, name)
            for appearance in LabelPillStyle.Appearance.allCases {
                let tag = SidebarTagStyle.resolve(colors, appearance: appearance)
                let fill = try XCTUnwrap(tag.fill, "\(name) \(appearance)")
                if appearance == .dark {
                    XCTAssertGreaterThanOrEqual(fill.difference(from: LabelPillStyle.sidebarSurface(.dark)),
                                                LabelPillStyle.minimumTagDifference, name)
                }
            }
        }
    }

    /// Light appearance: every preset color is visible as a sidebar tag (a
    /// fill that stands out from the sidebar, or the dot rule's outline)
    /// and as a list pill on every surface, WHITE included. The existing
    /// rules only, no new ones.
    func testEveryPresetIsDistinguishableInLightAppearance() throws {
        let sidebar = LabelPillStyle.sidebarSurface(.light)
        for (name, color) in GmailLabelColorPreset.colors {
            let tag = SidebarTagStyle.resolve(color.colors, appearance: .light)
            let fill = try XCTUnwrap(tag.fill, name)
            XCTAssertTrue(tag.outline != nil
                          || LabelPillStyle.fillStandsOut(fill, on: sidebar, shape: .dot), name)
            for surface in LabelPillStyle.Surface.allCases {
                let pill = LabelPillStyle.resolve(color.colors, appearance: .light, surface: surface)
                for behind in LabelPillStyle.surfaceColors(surface, .light) {
                    if pill.needsBorder {
                        XCTAssertGreaterThanOrEqual(pill.border.contrast(with: behind), 3, "\(name) \(surface)")
                    } else {
                        XCTAssertTrue(LabelPillStyle.fillStandsOut(pill.fill, on: behind, surface: surface),
                                      "\(name) \(surface)")
                    }
                }
                XCTAssertGreaterThanOrEqual(pill.text.contrast(with: pill.fill),
                                            LabelPillStyle.minimumTextContrast, name)
            }
        }
        let white = try XCTUnwrap(GmailLabelColorPreset.colors["WHITE"])
        XCTAssertNotNil(SidebarTagStyle.resolve(white.colors, appearance: .light).outline,
                        "white keeps its outline")
    }

    /// Every pair of the table is one `GmailLabelColor` accepts, so building
    /// `colors` never traps.
    func testEveryPresetPairBuildsAColor() {
        XCTAssertEqual(GmailLabelColorPreset.table.count, 21)
        for (name, pair) in GmailLabelColorPreset.table {
            XCTAssertNotNil(GmailLabelColor(background: pair.0, text: pair.1), name)
        }
    }

    /// All 21 pairs Google's Gmail MCP schema gives, kept independently of
    /// the table (not REST documentation).
    func testPresetTablePinsAllGooglePairs() {
        let expected: [String: (String, String)] = [
            "BLACK": ("#000000", "#ffffff"), "DARK_GRAY": ("#434343", "#ffffff"),
            "GRAY": ("#666666", "#ffffff"), "LIGHT_GRAY": ("#cccccc", "#000000"),
            "WHITE": ("#ffffff", "#000000"), "RED": ("#fb4c2f", "#ffffff"),
            "ORANGE": ("#ffad47", "#000000"), "YELLOW": ("#fad165", "#000000"),
            "GREEN": ("#16a765", "#ffffff"), "MINT": ("#43d692", "#000000"),
            "TEAL": ("#2da2bb", "#ffffff"), "BLUE": ("#4a86e8", "#ffffff"),
            "PURPLE": ("#a479e2", "#ffffff"), "PINK": ("#f691b2", "#000000"),
            "DARK_RED": ("#822111", "#ffffff"), "DARK_ORANGE": ("#a46a21", "#ffffff"),
            "DARK_GREEN": ("#076239", "#ffffff"), "DARK_BLUE": ("#1c4587", "#ffffff"),
            "DARK_PURPLE": ("#41236d", "#ffffff"), "DARK_PINK": ("#83334c", "#ffffff"),
            "BROWN": ("#7a4706", "#ffffff"),
        ]
        XCTAssertEqual(Set(GmailLabelColorPreset.colors.keys), Set(expected.keys))
        for (name, pair) in expected {
            XCTAssertEqual(GmailLabelColorPreset.colors[name]?.background, pair.0, name)
            XCTAssertEqual(GmailLabelColorPreset.colors[name]?.text, pair.1, name)
        }
    }
}
