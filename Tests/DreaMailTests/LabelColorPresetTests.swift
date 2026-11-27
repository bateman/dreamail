import XCTest
import GRDB

/// Gmail's `colorPreset` next to `color`: decoded as sent, stored (v71),
/// shown in the color sheet's "Current:" line, and used to draw a label
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

    private func row(_ colors: LabelColors = .none, preset: String? = nil, local: String? = nil) -> LabelRow {
        LabelRow(id: "a:L", accountId: "a", gmailLabelId: "L", name: "n", type: "user",
                 color: local, gmailBackgroundColor: colors.background,
                 gmailTextColor: colors.text, gmailColorPreset: preset)
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
            XCTAssertTrue(try db.columns(in: "label").map(\.name).contains("gmailColorPreset"))
        }
        let r = try stored(q)
        XCTAssertNil(r.gmailColorPreset)
        XCTAssertEqual(r.gmailBackgroundColor, "#eeeeee")
    }

    func testSyncStoresRefreshesAndClearsThePreset() throws {
        let q = try makeDB()
        let account = self.account
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                self.label(self.fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN")])
        }
        XCTAssertEqual(try stored(q).gmailColorPreset, "LABEL_COLOR_PRESET_DARK_GREEN")
        XCTAssertEqual(try stored(q).gmailBackgroundColor, "#eeeeee", "color is stored as sent")
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [
                self.label(self.fallback, preset: "LABEL_COLOR_PRESET_NEW_HUE")])
        }
        XCTAssertEqual(try stored(q).gmailColorPreset, "LABEL_COLOR_PRESET_NEW_HUE")
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: account, labels: [self.label(nil, preset: nil)])
        }
        XCTAssertNil(try stored(q).gmailColorPreset)
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

    // MARK: - "Current:" line

    func testCurrentLineShowsWhatGmailSent() {
        XCTAssertEqual(LabelCurrentColor.gmail(row(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN")),
                       "Current: #eeeeee, text #222222, preset DARK_GREEN (not in this palette)")
        XCTAssertEqual(LabelCurrentColor.gmail(row(darkGreen, preset: "LABEL_COLOR_PRESET_DARK_GREEN")),
                       "Current: #076239, text #ffffff, preset DARK_GREEN")
        XCTAssertEqual(LabelCurrentColor.gmail(row(preset: "LABEL_COLOR_PRESET_TEAL")),
                       "Current: none, preset TEAL")
        XCTAssertEqual(LabelCurrentColor.gmail(row(fallback)),
                       "Current: #eeeeee, text #222222, no preset (not in this palette)")
        XCTAssertEqual(LabelCurrentColor.gmail(row()), "Current: none, no preset")
        XCTAssertEqual(LabelCurrentColor.gmail(row(LabelColors(background: "oops", text: nil))),
                       "Current: unreadable value, no preset")
    }

    /// A preset the app does not know is shown too, exactly as sent.
    func testCurrentLineShowsAnUnknownPreset() {
        XCTAssertEqual(LabelCurrentColor.gmail(row(fallback, preset: "LABEL_COLOR_PRESET_NEW_HUE")),
                       "Current: #eeeeee, text #222222, preset NEW_HUE (not in this palette)")
        XCTAssertEqual(LabelCurrentColor.gmail(row(preset: "SOMETHING_ELSE")),
                       "Current: none, preset SOMETHING_ELSE")
        XCTAssertEqual(LabelCurrentColor.gmail(row(preset: "")), "Current: none, no preset")
    }

    /// The Mac-only line never shows Gmail's preset.
    func testLocalLineIgnoresThePreset() {
        XCTAssertEqual(LabelCurrentColor.local(row(preset: "LABEL_COLOR_PRESET_RED", local: "#eb5757"),
                                               palette: ["#EB5757"]),
                       "Current: #eb5757")
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

    /// The Mac-only color still comes first.
    func testLocalPickWinsOverThePreset() {
        XCTAssertEqual(row(fallback, preset: "LABEL_COLOR_PRESET_DARK_GREEN", local: "#EB5757").displayColors,
                       LabelColors(background: "#EB5757", text: nil))
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
