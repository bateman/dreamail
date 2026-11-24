import XCTest
import GRDB

/// `LabelPillStyle.resolve` — the one rule behind every label chip and dot —
/// over every color Gmail's API allows, and the path from a Gmail
/// labels.list response to the colors a pill is drawn with.
final class LabelColorStyleTests: XCTestCase {
    /// Gmail API `users.labels` → `Color`: "Only the following predefined
    /// set of color values are allowed" — the same 102 values for
    /// `backgroundColor` and `textColor`, and the API accepts any pairing.
    /// https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.labels
    static let gmailPalette: [String] = [
        "#000000", "#434343", "#666666", "#999999", "#cccccc", "#efefef", "#f3f3f3", "#ffffff",
        "#fb4c2f", "#ffad47", "#fad165", "#16a766", "#43d692", "#4a86e8", "#a479e2", "#f691b3",
        "#f6c5be", "#ffe6c7", "#fef1d1", "#b9e4d0", "#c6f3de", "#c9daf8", "#e4d7f5", "#fcdee8",
        "#efa093", "#ffd6a2", "#fce8b3", "#89d3b2", "#a0eac9", "#a4c2f4", "#d0bcf1", "#fbc8d9",
        "#e66550", "#ffbc6b", "#fcda83", "#44b984", "#68dfa9", "#6d9eeb", "#b694e8", "#f7a7c0",
        "#cc3a21", "#eaa041", "#f2c960", "#149e60", "#3dc789", "#3c78d8", "#8e63ce", "#e07798",
        "#ac2b16", "#cf8933", "#d5ae49", "#0b804b", "#2a9c68", "#285bac", "#653e9b", "#b65775",
        "#822111", "#a46a21", "#aa8831", "#076239", "#1a764d", "#1c4587", "#41236d", "#83334c",
        "#464646", "#e7e7e7", "#0d3472", "#b6cff5", "#0d3b44", "#98d7e4", "#3d188e", "#e3d7ff",
        "#711a36", "#fbd3e0", "#8a1c0a", "#f2b2a8", "#7a2e0b", "#ffc8af", "#7a4706", "#ffdeb5",
        "#594c05", "#fbe983", "#684e07", "#fdedc1", "#0b4f30", "#b3efd3", "#04502e", "#a2dcc1",
        "#c2c2c2", "#4986e7", "#2da2bb", "#b99aff", "#994a64", "#f691b2", "#ff7537", "#ffad46",
        "#662e37", "#ebdbde", "#cca6ac", "#094228", "#42d692", "#16a765",
    ]

    /// Every pairing the API allows, plus the label with no color, plus a
    /// background with no (or a malformed) text color.
    private static var allColorCases: [LabelColors] {
        var cases: [LabelColors] = [.none, LabelColors(background: nil, text: "#000000"),
                                    LabelColors(background: "not-a-color", text: "#ffffff")]
        for bg in gmailPalette {
            cases.append(LabelColors(background: bg, text: nil))
            cases.append(LabelColors(background: bg, text: "#zzzzzz"))
            for text in gmailPalette {
                cases.append(LabelColors(background: bg, text: text))
            }
        }
        return cases
    }

    func testPaletteIsTheDocumentedList() {
        XCTAssertEqual(Self.gmailPalette.count, 102)
        XCTAssertEqual(Set(Self.gmailPalette).count, 102)
        for hex in Self.gmailPalette {
            XCTAssertNotNil(LabelRGB(hexString: hex), hex)
        }
    }

    // MARK: - Contrast over the full palette

    func testTextIsReadableOnFillForEveryPairInBothAppearances() {
        for appearance in LabelPillStyle.Appearance.allCases {
            for surface in LabelPillStyle.Surface.allCases {
                for colors in Self.allColorCases {
                    let style = LabelPillStyle.resolve(colors, appearance: appearance, surface: surface)
                    let ratio = style.text.contrast(with: style.fill)
                    if ratio < LabelPillStyle.minimumTextContrast {
                        XCTFail("\(colors) \(appearance) \(surface): text contrast \(ratio)")
                    }
                }
            }
        }
    }

    func testPillIsVisibleAgainstEverySurfaceInBothAppearances() {
        for appearance in LabelPillStyle.Appearance.allCases {
            for surface in LabelPillStyle.Surface.allCases {
                for colors in Self.allColorCases {
                    let style = LabelPillStyle.resolve(colors, appearance: appearance, surface: surface)
                    // Every color the surface takes (the selection is blue
                    // or, in an inactive window, grey).
                    for behind in LabelPillStyle.surfaceColors(surface, appearance) {
                        let fillEdge = style.fill.difference(from: behind)
                        if style.needsBorder {
                            // The outline carries the edge: WCAG non-text 3:1.
                            let borderEdge = style.border.contrast(with: behind)
                            if borderEdge < 3 {
                                XCTFail("\(colors) \(appearance) \(surface): border contrast \(borderEdge)")
                            }
                        } else if fillEdge < LabelPillStyle.minimumEdgeDifference {
                            XCTFail("\(colors) \(appearance) \(surface): fill difference \(fillEdge), no border")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Fill and text choice

    func testFillIsGmailBackgroundSolid() {
        for bg in Self.gmailPalette {
            let style = LabelPillStyle.resolve(LabelColors(background: bg, text: nil), appearance: .light)
            XCTAssertEqual(style.fill, LabelRGB(hexString: bg), bg)
        }
    }

    func testGmailTextColorIsKeptWhenReadable() {
        // Gmail's own pairs from its label color picker.
        let pairs = [("#fad165", "#000000"), ("#4a86e8", "#ffffff"),
                     ("#000000", "#ffffff"), ("#16a766", "#ffffff"), ("#fb4c2f", "#ffffff")]
        for (bg, text) in pairs {
            let fill = LabelRGB(hexString: bg)!
            let own = LabelRGB(hexString: text)!
            let style = LabelPillStyle.resolve(LabelColors(background: bg, text: text), appearance: .light)
            if own.contrast(with: fill) >= 4.5 {
                XCTAssertEqual(style.text, own, "\(bg)/\(text)")
            } else {
                XCTAssertNotEqual(style.text, own, "\(bg)/\(text)")
            }
        }
        // #fad165 with black text: 4.5:1 easily, so Gmail's black stays.
        XCTAssertEqual(LabelPillStyle.resolve(LabelColors(background: "#fad165", text: "#000000"),
                                              appearance: .dark).text, .black)
    }

    func testUnreadableGmailTextFallsBackToBlackOrWhite() {
        // The owner's case: pale yellow text on a pale yellow fill.
        let style = LabelPillStyle.resolve(LabelColors(background: "#fad165", text: "#fce8b3"),
                                           appearance: .light)
        XCTAssertEqual(style.fill, LabelRGB(hexString: "#fad165"))
        XCTAssertEqual(style.text, .black)
        let dark = LabelPillStyle.resolve(LabelColors(background: "#1c4587", text: "#285bac"),
                                          appearance: .light)
        XCTAssertEqual(dark.text, .white)
    }

    func testNoColorIsNeutralGreyWithReadableText() {
        for appearance in LabelPillStyle.Appearance.allCases {
            let style = LabelPillStyle.resolve(.none, appearance: appearance)
            XCTAssertEqual(style.fill, LabelPillStyle.neutralFill(appearance))
            XCTAssertEqual(style.text, LabelPillStyle.neutralText(appearance))
            for grey in [style.fill, style.text] {
                XCTAssertEqual(grey.r, grey.g)
                XCTAssertEqual(grey.g, grey.b)
            }
            XCTAssertGreaterThanOrEqual(style.text.contrast(with: style.fill), 4.5)
            // Dark grey on light grey (light), light grey on dark grey (dark).
            XCTAssertEqual(style.fill.luminance > style.text.luminance, appearance == .light)
        }
        // A malformed background is treated like no color, and its text
        // color is not trusted either.
        let malformed = LabelPillStyle.resolve(LabelColors(background: "#12", text: "#dddddd"),
                                               appearance: .light)
        XCTAssertEqual(malformed.fill, LabelPillStyle.neutralFill(.light))
        XCTAssertEqual(malformed.text, LabelPillStyle.neutralText(.light))
    }

    // MARK: - Borders

    /// Gmail's pastel rows of the palette (the colors its picker offers
    /// for light labels) and its light "legacy" pastels.
    static let palePalette: [String] = [
        "#f6c5be", "#ffe6c7", "#fef1d1", "#b9e4d0", "#c6f3de", "#c9daf8", "#e4d7f5", "#fcdee8",
        "#efa093", "#ffd6a2", "#fce8b3", "#89d3b2", "#a0eac9", "#a4c2f4", "#d0bcf1", "#fbc8d9",
        "#b6cff5", "#98d7e4", "#e3d7ff", "#fbd3e0", "#f2b2a8", "#ffc8af", "#ffdeb5", "#fbe983",
        "#fdedc1", "#b3efd3", "#a2dcc1", "#ebdbde", "#cca6ac",
    ]

    /// Like Gmail: no outline on the pale colors or the neutral chip, on
    /// unread (white) and read (wash) rows in light mode.
    func testPaleColorsAndNeutralChipHaveNoOutlineOnLightRows() {
        for surface in [LabelPillStyle.Surface.content, .readRow] {
            for bg in Self.palePalette {
                let style = LabelPillStyle.resolve(LabelColors(background: bg, text: nil),
                                                   appearance: .light, surface: surface)
                XCTAssertFalse(style.needsBorder, "\(bg) \(surface)")
            }
            XCTAssertFalse(LabelPillStyle.resolve(.none, appearance: .light, surface: surface).needsBorder,
                           "neutral \(surface)")
            XCTAssertFalse(LabelPillStyle.resolve(.none, appearance: .dark, surface: surface).needsBorder,
                           "neutral dark \(surface)")
        }
    }

    /// The outline appears exactly when the fill is closer than the
    /// threshold to some color of the surface, over the whole palette.
    func testOutlineOnlyBelowTheThreshold() {
        for appearance in LabelPillStyle.Appearance.allCases {
            for surface in LabelPillStyle.Surface.allCases {
                for bg in Self.gmailPalette.map(Optional.some) + [nil] {
                    let style = LabelPillStyle.resolve(LabelColors(background: bg, text: nil),
                                                       appearance: appearance, surface: surface)
                    let closest = LabelPillStyle.surfaceColors(surface, appearance)
                        .map { style.fill.difference(from: $0) }.min() ?? .infinity
                    XCTAssertEqual(style.needsBorder, closest < LabelPillStyle.minimumEdgeDifference,
                                   "\(bg ?? "none") \(appearance) \(surface): \(closest)")
                }
            }
        }
    }

    /// Which Gmail colors still get an outline on the list's light rows:
    /// only the near-white greys.
    func testOnlyNearWhiteGreysGetAnOutlineOnLightRows() {
        func outlined(_ surface: LabelPillStyle.Surface) -> Set<String> {
            Set(Self.gmailPalette.filter {
                LabelPillStyle.resolve(LabelColors(background: $0, text: nil),
                                       appearance: .light, surface: surface).needsBorder
            })
        }
        XCTAssertEqual(outlined(.content), ["#ffffff", "#f3f3f3"])
        XCTAssertEqual(outlined(.readRow), ["#ffffff", "#f3f3f3", "#efefef", "#e7e7e7"])
        // Dark rows: every Gmail color stands out, black included.
        for surface in [LabelPillStyle.Surface.content, .readRow] {
            for bg in Self.gmailPalette {
                XCTAssertFalse(LabelPillStyle.resolve(LabelColors(background: bg, text: nil),
                                                      appearance: .dark, surface: surface).needsBorder,
                               "\(bg) dark \(surface)")
            }
        }
    }

    /// A pale yellow as light as the read-row wash: the WCAG ratio sees
    /// nothing, the color difference sees the hue.
    func testDifferenceCountsHueNotOnlyLuminance() {
        let yellow = LabelRGB(hex: 0xFEF1D1)
        let wash = LabelPillStyle.surfaceColor(.readRow, .light)
        XCTAssertLessThan(yellow.contrast(with: wash), 1.01)
        XCTAssertGreaterThan(yellow.difference(from: wash), 15)
        XCTAssertEqual(LabelRGB.white.difference(from: .white), 0, accuracy: 1e-9)
        XCTAssertEqual(LabelRGB.black.difference(from: .white), 100, accuracy: 0.01)
    }

    func testSelectionOutlineCoversBlueAndInactiveHighlight() {
        XCTAssertEqual(LabelPillStyle.surfaceColors(.selection, .light).count, 2)
        XCTAssertEqual(LabelPillStyle.surfaceColors(.selection, .dark).count, 2)
        // A blue close to the active highlight still differs by hue and
        // lightness: no outline.
        XCTAssertFalse(LabelPillStyle.resolve(LabelColors(background: "#3c78d8", text: "#ffffff"),
                                              appearance: .light, surface: .selection).needsBorder)
        // The neutral chip on the inactive-window highlight (#DCDCDC): an
        // outline, though none on a white row.
        let grey = LabelPillStyle.resolve(.none, appearance: .light, surface: .selection)
        XCTAssertTrue(grey.needsBorder)
        XCTAssertFalse(LabelPillStyle.resolve(.none, appearance: .light, surface: .content).needsBorder)
        // Dark: a grey close to the inactive #464646.
        let darkGrey = LabelPillStyle.resolve(LabelColors(background: "#434343", text: nil),
                                              appearance: .dark, surface: .selection)
        XCTAssertTrue(darkGrey.needsBorder)
        // A mid grey outline would vanish on the blue highlight: black in
        // light (3.8:1 on blue, 15:1 on grey), white in dark.
        XCTAssertEqual(grey.border, .black)
        XCTAssertEqual(darkGrey.border, .white)
    }

    // MARK: - Read (dimmed) rows

    /// Read rows sit on a 5% primary wash and their sender and subject are
    /// dimmed; the pill is not dimmed with them. The wash is the surface
    /// the outline rule is checked against, and the pill's own colors are
    /// the same as on an unread row.
    func testReadRowKeepsPillColorsAndChecksEdgeAgainstTheWash() {
        for appearance in LabelPillStyle.Appearance.allCases {
            let content = LabelPillStyle.surfaceColor(.content, appearance)
            let wash = LabelPillStyle.surfaceColor(.readRow, appearance)
            XCTAssertNotEqual(content, wash)
            XCTAssertLessThan(content.contrast(with: wash), 1.2)
            for bg in Self.gmailPalette {
                let colors = LabelColors(background: bg, text: nil)
                let unread = LabelPillStyle.resolve(colors, appearance: appearance, surface: .content)
                let read = LabelPillStyle.resolve(colors, appearance: appearance, surface: .readRow)
                XCTAssertEqual(read.fill, unread.fill, bg)
                XCTAssertEqual(read.text, unread.text, bg)
                XCTAssertGreaterThanOrEqual(read.text.contrast(with: read.fill), 4.5, bg)
                XCTAssertTrue(read.needsBorder || LabelPillStyle.fillStandsOut(read.fill, on: wash), bg)
            }
        }
        // #f3f3f3 is almost exactly the light wash: it gets an outline there.
        XCTAssertTrue(LabelPillStyle.resolve(LabelColors(background: "#f3f3f3", text: nil),
                                             appearance: .light, surface: .readRow).needsBorder)
    }

    // MARK: - From Gmail's response to the pill

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: "a@x.com", displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
        }
        return q
    }

    /// A labels.list response as Gmail sends it, decoded and synced: the
    /// stored row's display colors are Gmail's pair, and the pill is drawn
    /// with Gmail's background as its fill and Gmail's text when readable.
    func testGmailColorFromLabelsListReachesThePill() throws {
        let json = Data("""
            {"labels": [
              {"id": "INBOX", "name": "INBOX", "type": "system"},
              {"id": "Label_7", "name": "$/paypal", "type": "user",
               "color": {"textColor": "#000000", "backgroundColor": "#fad165"}},
              {"id": "Label_8", "name": "mail", "type": "user",
               "color": {"textColor": "#0b4f30", "backgroundColor": "#b3efd3"}},
              {"id": "Label_9", "name": "plain", "type": "user"}
            ]}
            """.utf8)
        let list = try JSONDecoder().decode(GLabelList.self, from: json)
        let q = try makeDB()
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: "a@x.com", labels: list.labels ?? [])
        }
        let rows = try q.read { db in try LabelRow.fetchAll(db) }
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })

        let paypal = try XCTUnwrap(byName["$/paypal"])
        XCTAssertNil(paypal.color, "Gmail's color is not a local pick")
        XCTAssertEqual(paypal.displayColors, LabelColors(background: "#fad165", text: "#000000"))
        let style = LabelPillStyle.resolve(paypal.displayColors, appearance: .light)
        XCTAssertEqual(style.fill, LabelRGB(hexString: "#fad165"))
        XCTAssertEqual(style.text, .black)

        let mail = try XCTUnwrap(byName["mail"])
        XCTAssertEqual(mail.displayColors, LabelColors(background: "#b3efd3", text: "#0b4f30"))
        let mailStyle = LabelPillStyle.resolve(mail.displayColors, appearance: .dark)
        XCTAssertEqual(mailStyle.fill, LabelRGB(hexString: "#b3efd3"))
        XCTAssertEqual(mailStyle.text, LabelRGB(hexString: "#0b4f30"))

        XCTAssertEqual(try XCTUnwrap(byName["plain"]).displayColors, .none)
    }

    /// Colors from the API are stored only as 6-digit hex, normalized to
    /// lowercase `#rrggbb`; anything else is stored as nil.
    func testMalformedGmailColorIsNotStored() throws {
        XCTAssertEqual(LabelRGB.normalizedHex(" #FAD165 "), "#fad165")
        XCTAssertEqual(LabelRGB.normalizedHex("16a766"), "#16a766")
        for bad in [nil, "", "#", "#fff", "#fad1655", "fad16", "#gggggg", "#ｆａｄ１６５",
                    "red", "#fad165; DROP", String(repeating: "a", count: 10_000)] {
            XCTAssertNil(LabelRGB.normalizedHex(bad), String(describing: bad?.prefix(20)))
        }
        let q = try makeDB()
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: "a@x.com", labels: [
                GLabel(id: "Label_1", name: "Odd", type: "user",
                       color: GLabel.GColor(backgroundColor: String(repeating: "f", count: 500),
                                            textColor: "#FFFFFF")),
            ])
        }
        let row = try XCTUnwrap(try q.read { db in try LabelRow.fetchOne(db, key: "a@x.com:Label_1") })
        XCTAssertNil(row.gmailBackgroundColor)
        XCTAssertEqual(row.gmailTextColor, "#ffffff")
        // No usable background: neutral grey, and the text color is not
        // used without its background.
        let style = LabelPillStyle.resolve(row.displayColors, appearance: .light)
        XCTAssertEqual(style.fill, LabelPillStyle.neutralFill(.light))
        XCTAssertEqual(style.text, LabelPillStyle.neutralText(.light))
    }

    /// A label whose color was removed in Gmail goes back to neutral grey.
    func testColorRemovedInGmailFallsBackToNone() throws {
        let q = try makeDB()
        try q.write { db in
            try SyncEngine.applyLabels(db, accountId: "a@x.com", labels: [
                GLabel(id: "Label_1", name: "Work", type: "user",
                       color: GLabel.GColor(backgroundColor: "#fad165", textColor: "#000000")),
            ])
            try SyncEngine.applyLabels(db, accountId: "a@x.com", labels: [
                GLabel(id: "Label_1", name: "Work", type: "user", color: nil),
            ])
        }
        let row = try XCTUnwrap(try q.read { db in try LabelRow.fetchOne(db, key: "a@x.com:Label_1") })
        XCTAssertEqual(row.displayColors, .none)
    }

    /// A color changed in Gmail shows on the next sync; a local pick from
    /// the organizer still wins, and clearing it shows Gmail's color again.
    func testGmailColorChangeIsFollowedAndLocalPickWins() throws {
        let q = try makeDB()
        func sync(_ bg: String, _ text: String) throws {
            try q.write { db in
                try SyncEngine.applyLabels(db, accountId: "a@x.com", labels: [
                    GLabel(id: "Label_1", name: "Work", type: "user",
                           color: GLabel.GColor(backgroundColor: bg, textColor: text)),
                ])
            }
        }
        func row() throws -> LabelRow {
            try XCTUnwrap(try q.read { db in try LabelRow.fetchOne(db, key: "a@x.com:Label_1") })
        }
        try sync("#fad165", "#000000")
        try sync("#4a86e8", "#ffffff")
        XCTAssertEqual(try row().displayColors, LabelColors(background: "#4a86e8", text: "#ffffff"))

        try q.write { db in
            try db.execute(sql: "UPDATE label SET color = '#EB5757' WHERE id = 'a@x.com:Label_1'")
        }
        try sync("#16a766", "#ffffff")
        XCTAssertEqual(try row().displayColors, LabelColors(background: "#EB5757", text: nil))
        XCTAssertEqual(try row().gmailBackgroundColor, "#16a766")

        try q.write { db in
            try db.execute(sql: "UPDATE label SET color = NULL WHERE id = 'a@x.com:Label_1'")
        }
        XCTAssertEqual(try row().displayColors, LabelColors(background: "#16a766", text: "#ffffff"))
    }

    /// Up to v50 `color` held Gmail's background color, seeded once and
    /// never refreshed. v51 keeps organizer picks and moves the rest to
    /// `gmailBackgroundColor`, so pills keep their color until the next
    /// sync writes Gmail's current pair.
    func testV51ClearsGmailSeededColorsAndKeepsOrganizerPicks() throws {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q, upTo: "v50")
        try q.write { db in
            try db.execute(sql: "INSERT INTO account (id, displayName, senderName) VALUES ('a@x.com', 'P', '')")
            for (id, color) in [("Label_1", "'#fad165'"), ("Label_2", "'#eb5757'"),
                                ("Label_3", "NULL")] {
                try db.execute(sql: """
                    INSERT INTO label (id, accountId, gmailLabelId, name, type, color)
                    VALUES ('a@x.com:\(id)', 'a@x.com', '\(id)', '\(id)', 'user', \(color))
                    """)
            }
        }
        try AppDatabase.migrator.migrate(q)
        let rows = try q.read { db in try LabelRow.fetchAll(db) }
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.gmailLabelId, $0) })
        XCTAssertNil(byId["Label_1"]?.color)
        XCTAssertEqual(byId["Label_1"]?.gmailBackgroundColor, "#fad165")
        XCTAssertEqual(byId["Label_1"]?.displayColors, LabelColors(background: "#fad165", text: nil))
        XCTAssertEqual(byId["Label_2"]?.color, "#eb5757")
        XCTAssertNil(byId["Label_2"]?.gmailBackgroundColor)
        XCTAssertNil(byId["Label_3"]?.color)
        XCTAssertNil(byId["Label_3"]?.gmailBackgroundColor)
    }
}
