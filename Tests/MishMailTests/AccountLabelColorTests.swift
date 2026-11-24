import AppKit
import GRDB
import SwiftUI
import XCTest

/// The color of an account's label pill: stored on the account row as
/// `#rrggbb` (NULL = default), drawn with `LabelPillStyle.resolve`, and
/// converted from the system color picker.
final class AccountLabelColorTests: XCTestCase {

    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        return q
    }

    private func insertAccount(_ db: Database, _ id: String) throws {
        try Account(id: id, displayName: "Personal", historyId: nil,
                    lastSyncAt: nil, senderName: "Jane").insert(db)
    }

    private func stored(_ db: Database, _ id: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT labelColor FROM account WHERE id = ?",
                            arguments: [id])
    }

    // MARK: - Storage

    func testColorIsSavedNormalizedAndReadBack() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            try AccountLabelColor.set(db, accountId: "a@x.com", hex: " #AABBCC ")
        }
        try q.read { db in
            XCTAssertEqual(try self.stored(db, "a@x.com"), "#aabbcc")
            let account = try XCTUnwrap(Account.fetchOne(db, key: "a@x.com"))
            XCTAssertEqual(account.labelColor, "#aabbcc")
            XCTAssertEqual(AccountLabelColor.colors(for: account).background, "#aabbcc")
        }
    }

    func testNilOrMalformedResetsToDefault() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            try AccountLabelColor.set(db, accountId: "a@x.com", hex: "#123456")
            try AccountLabelColor.set(db, accountId: "a@x.com", hex: nil)
            XCTAssertNil(try self.stored(db, "a@x.com"))
            try AccountLabelColor.set(db, accountId: "a@x.com", hex: "#123456")
            try AccountLabelColor.set(db, accountId: "a@x.com", hex: "red; DROP TABLE account")
            XCTAssertNil(try self.stored(db, "a@x.com"), "no arbitrary string is stored")
            try AccountLabelColor.set(db, accountId: "a@x.com", hex: "")
            XCTAssertNil(try self.stored(db, "a@x.com"))
        }
        try q.read { db in
            let account = try XCTUnwrap(Account.fetchOne(db, key: "a@x.com"))
            XCTAssertEqual(AccountLabelColor.colors(for: account).background,
                           AccountLabelColor.defaultHex(for: "a@x.com"))
        }
    }

    func testMalformedStoredValueFallsBackToDefault() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            // Written behind the setter's back (an older build, a hand edit).
            try db.execute(sql: "UPDATE account SET labelColor = 'zzz' WHERE id = 'a@x.com'")
        }
        try q.read { db in
            let account = try XCTUnwrap(Account.fetchOne(db, key: "a@x.com"))
            XCTAssertEqual(AccountLabelColor.colors(for: account).background,
                           AccountLabelColor.defaultHex(for: "a@x.com"))
        }
        for bad in ["", "#12345", "#1234567", "#gggggg", "blue", "#12 456"] {
            XCTAssertEqual(AccountLabelColor.resolvedHex(stored: bad, accountId: "b@x.com"),
                           AccountLabelColor.defaultHex(for: "b@x.com"), bad)
        }
    }

    func testColorGoesWithTheAccountAndOthersKeepTheirs() throws {
        let q = try makeDB()
        try q.write { db in
            try self.insertAccount(db, "a@x.com")
            try self.insertAccount(db, "b@x.com")
            try AccountLabelColor.set(db, accountId: "a@x.com", hex: "#112233")
            try AccountLabelColor.set(db, accountId: "b@x.com", hex: "#445566")
            try AccountLifecycle.purgeAccount(db, id: "a@x.com")
        }
        try q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM account WHERE labelColor = '#112233'
                """), 0)
            XCTAssertNil(try Account.fetchOne(db, key: "a@x.com"))
            XCTAssertEqual(try self.stored(db, "b@x.com"), "#445566")
        }
        // Added again later: it starts from the default, not the old color.
        try q.write { db in try self.insertAccount(db, "a@x.com") }
        try q.read { db in XCTAssertNil(try self.stored(db, "a@x.com")) }
    }

    func testSignInAgainKeepsTheColor() {
        var existing = Account(id: "a@x.com", displayName: "Personal", historyId: nil,
                               lastSyncAt: nil, senderName: "")
        existing.labelColor = "#112233"
        let after = AccountLifecycle.accountAfterSignIn(email: "a@x.com", name: "Jane",
                                                        existing: existing)
        XCTAssertEqual(after.labelColor, "#112233")
        XCTAssertNil(AccountLifecycle.accountAfterSignIn(email: "n@x.com", name: "N",
                                                         existing: nil).labelColor)
    }

    // MARK: - Migration

    func testV52AddsNullableLabelColorKeepingAccounts() throws {
        let q = try DatabaseQueue()
        let migrator = AppDatabase.migrator
        try migrator.migrate(q, upTo: "v51")
        try q.write { db in
            XCTAssertFalse(try db.columns(in: "account").map(\.name).contains("labelColor"))
            try db.execute(sql: """
                INSERT INTO account (id, displayName, senderName) VALUES ('a@x.com', 'Fund', 'Jane')
                """)
        }
        try migrator.migrate(q)
        try q.read { db in
            XCTAssertTrue(try db.columns(in: "account").map(\.name).contains("labelColor"))
            let account = try XCTUnwrap(Account.fetchOne(db, key: "a@x.com"))
            XCTAssertEqual(account.displayName, "Fund")
            XCTAssertNil(account.labelColor, "existing accounts keep the default color")
        }
    }

    // MARK: - Default color

    func testDefaultFollowsTheAvatarHue() {
        XCTAssertEqual(AccountLabelColor.defaultPalette.count, 8,
                       "one hex per Color.stable palette entry")
        for hex in AccountLabelColor.defaultPalette {
            XCTAssertEqual(LabelRGB.normalizedHex(hex), hex)
        }
        for id in ["a@x.com", "fabio@example.com", "you@example.com", ""] {
            let index = Color.stableIndex(for: id, count: 8)
            XCTAssertEqual(AccountLabelColor.defaultHex(for: id),
                           AccountLabelColor.defaultPalette[index], id)
        }
        // Deterministic: the same account always gets the same default.
        XCTAssertEqual(AccountLabelColor.defaultHex(for: "a@x.com"),
                       AccountLabelColor.defaultHex(for: "a@x.com"))
    }

    // MARK: - Pill style

    /// Every color the editor offers by default (account defaults and the
    /// organizer swatches) plus a sample of picker colors, including
    /// near-white and near-black.
    private static var pillColors: [String] {
        AccountLabelColor.defaultPalette
            + Color.labelPalette.map { $0.hex }
            + ["#ffffff", "#f7f7f5", "#000000", "#232323", "#191919", "#808080",
               "#ffff00", "#00ff00", "#e4d7f5", "#7f7f7f"]
    }

    func testPillTextIsReadableAndPillIsVisibleInBothAppearances() {
        for appearance in LabelPillStyle.Appearance.allCases {
            for surface in [LabelPillStyle.Surface.sidebar, .content] {
                for hex in Self.pillColors {
                    let style = LabelPillStyle.resolve(LabelColors(background: hex, text: nil),
                                                       appearance: appearance, surface: surface)
                    XCTAssertEqual(style.fill, LabelRGB(hexString: hex), "solid fill \(hex)")
                    let text = style.text.contrast(with: style.fill)
                    XCTAssertGreaterThanOrEqual(text, LabelPillStyle.minimumTextContrast,
                                                "\(hex) \(appearance) \(surface)")
                    for behind in LabelPillStyle.surfaceColors(surface, appearance) {
                        if style.needsBorder {
                            XCTAssertGreaterThanOrEqual(style.border.contrast(with: behind), 3,
                                                        "\(hex) \(appearance) \(surface) border")
                        } else {
                            XCTAssertGreaterThanOrEqual(
                                style.fill.contrast(with: behind),
                                LabelPillStyle.minimumEdgeContrast,
                                "\(hex) \(appearance) \(surface) edge")
                        }
                    }
                }
            }
        }
    }

    func testDefaultPillIsNoLongerPaleOnPale() {
        for id in ["a@x.com", "fabio@example.com", "you@example.com"] {
            let colors = AccountLabelColor.colors(for: Account(
                id: id, displayName: "Personale", historyId: nil, lastSyncAt: nil,
                senderName: "F"))
            XCTAssertNil(colors.text, "text color is left to the contrast rule")
            for appearance in LabelPillStyle.Appearance.allCases {
                let style = LabelPillStyle.resolve(colors, appearance: appearance,
                                                   surface: .sidebar)
                XCTAssertEqual(style.fill, LabelRGB(hexString: AccountLabelColor.defaultHex(for: id)))
                XCTAssertTrue(style.text == .black || style.text == .white)
                XCTAssertGreaterThanOrEqual(style.text.contrast(with: style.fill), 4.5)
            }
        }
    }

    func testSidebarSurfaceMatchesTheSidebarBackground() {
        XCTAssertEqual(LabelPillStyle.surfaceColors(.sidebar, .light), [LabelRGB(hex: 0xF7F7F5)])
        XCTAssertEqual(LabelPillStyle.surfaceColors(.sidebar, .dark), [LabelRGB(hex: 0x232323)])
    }

    // MARK: - Picker conversion

    func testSRGBColorsConvertExactly() {
        XCTAssertEqual(AccountLabelColor.hex(from: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6,
                                                           alpha: 1)), "#336699")
        XCTAssertEqual(AccountLabelColor.hex(from: Color(.sRGB, red: 0.2, green: 0.4, blue: 0.6)),
                       "#336699")
        XCTAssertEqual(AccountLabelColor.hex(from: NSColor(srgbRed: 1, green: 0, blue: 0,
                                                           alpha: 0.3)), "#ff0000",
                       "alpha is ignored: pills are opaque")
    }

    func testStoredColorsRoundTripThroughThePicker() {
        for hex in Self.pillColors {
            let normalized = LabelRGB.normalizedHex(hex)
            let ns = AccountLabelColor.nsColor(hex: hex, accountId: "a@x.com")
            XCTAssertEqual(AccountLabelColor.hex(from: ns), normalized, hex)
            XCTAssertEqual(AccountLabelColor.hex(from: Color(nsColor: ns)), normalized, hex)
        }
        // The default (nil) shows the default color in the picker.
        XCTAssertEqual(AccountLabelColor.hex(from: AccountLabelColor.nsColor(hex: nil,
                                                                             accountId: "a@x.com")),
                       AccountLabelColor.defaultHex(for: "a@x.com"))
    }

    func testWideGamutColorsClampToTheSRGBEdge() throws {
        let extended = NSColor(colorSpace: .extendedSRGB,
                               components: [1.2, -0.1, 0.5, 1], count: 4)
        let clamped = try XCTUnwrap(LabelRGB(hexString: AccountLabelColor.hex(from: extended)))
        XCTAssertEqual(clamped.r, 1, accuracy: 0.001)
        XCTAssertEqual(clamped.g, 0, accuracy: 0.001)
        XCTAssertEqual(clamped.b, 0.5, accuracy: 0.05)

        let p3Red = NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)
        let hex = try XCTUnwrap(AccountLabelColor.hex(from: p3Red))
        let rgb = try XCTUnwrap(LabelRGB(hexString: hex))
        XCTAssertEqual(rgb.r, 1, accuracy: 0.001)
        XCTAssertLessThan(rgb.g, 0.05)
        XCTAssertLessThan(rgb.b, 0.05)
    }

    func testGreysStayGrey() throws {
        XCTAssertEqual(AccountLabelColor.hex(from: NSColor(white: 0, alpha: 1)), "#000000")
        XCTAssertEqual(AccountLabelColor.hex(from: NSColor(white: 1, alpha: 1)), "#ffffff")
        for white in [0.25, 0.5, 0.75] {
            let hex = try XCTUnwrap(AccountLabelColor.hex(from: NSColor(white: white, alpha: 1)))
            let rgb = try XCTUnwrap(LabelRGB(hexString: hex))
            XCTAssertEqual(rgb.r, rgb.g, accuracy: 1.5 / 255, hex)
            XCTAssertEqual(rgb.g, rgb.b, accuracy: 1.5 / 255, hex)
        }
    }

    func testEveryResultIsAValidStoredValue() {
        let samples: [NSColor] = [
            .systemRed, .systemPurple, .labelColor, .controlAccentColor,
            NSColor(calibratedRed: 0.9, green: 0.1, blue: 0.3, alpha: 1),
            NSColor(deviceCyan: 1, magenta: 0, yellow: 0, black: 0, alpha: 1),
        ]
        for color in samples {
            guard let hex = AccountLabelColor.hex(from: color) else {
                XCTFail("\(color) has an RGB form"); continue
            }
            XCTAssertEqual(LabelRGB.normalizedHex(hex), hex)
        }
    }
}
