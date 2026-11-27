import XCTest

final class AccountRailPaletteTests: XCTestCase {
    private let sidebarLight = LabelRGB(hex: 0xF7F7F5)
    private let sidebarDark = LabelRGB(hex: 0x232323)
    /// The unread badge's fill (`AccountAvatarView.unreadBadge`).
    private let badgeRed = LabelRGB(r: 0.78, g: 0.13, b: 0.11)

    func testRailIsDarkerThanTheSidebarInBothAppearances() {
        let light = LabelRGB(hex: AccountRailPalette.backgroundLight)
        let dark = LabelRGB(hex: AccountRailPalette.backgroundDark)
        XCTAssertLessThan(light.luminance, sidebarLight.luminance)
        XCTAssertLessThan(dark.luminance, sidebarDark.luminance)
    }

    func testGlyphsAreReadableOnTheRail() {
        XCTAssertGreaterThanOrEqual(
            LabelRGB(hex: AccountRailPalette.glyphLight)
                .contrast(with: LabelRGB(hex: AccountRailPalette.backgroundLight)), 4.5)
        XCTAssertGreaterThanOrEqual(
            LabelRGB(hex: AccountRailPalette.glyphDark)
                .contrast(with: LabelRGB(hex: AccountRailPalette.backgroundDark)), 4.5)
    }

    func testBadgeStandsOutFromTheRail() {
        XCTAssertGreaterThanOrEqual(
            badgeRed.contrast(with: LabelRGB(hex: AccountRailPalette.backgroundLight)), 2.5)
        XCTAssertGreaterThanOrEqual(
            badgeRed.contrast(with: LabelRGB(hex: AccountRailPalette.backgroundDark)), 2.5)
    }

    func testRailSurfaceFollowsThePalette() {
        XCTAssertEqual(AccountRingStyle.surfaceColors(.rail, .light),
                       [LabelRGB(hex: AccountRailPalette.backgroundLight)])
        XCTAssertEqual(AccountRingStyle.surfaceColors(.rail, .dark),
                       [LabelRGB(hex: AccountRailPalette.backgroundDark)])
    }

    func testIdleRingIsVisibleOnTheRailInBothAppearances() {
        XCTAssertGreaterThanOrEqual(
            LabelRGB(hex: AccountRailPalette.idleRingLight)
                .contrast(with: LabelRGB(hex: AccountRailPalette.backgroundLight)), 1.5)
        XCTAssertGreaterThanOrEqual(
            LabelRGB(hex: AccountRailPalette.idleRingDark)
                .contrast(with: LabelRGB(hex: AccountRailPalette.backgroundDark)), 1.5)
    }

    /// The idle ring must stay quieter than the glyph (the selected look).
    func testIdleRingIsSofterThanTheSelectionRing() {
        XCTAssertLessThan(
            LabelRGB(hex: AccountRailPalette.idleRingLight)
                .contrast(with: LabelRGB(hex: AccountRailPalette.backgroundLight)),
            LabelRGB(hex: AccountRailPalette.glyphLight)
                .contrast(with: LabelRGB(hex: AccountRailPalette.backgroundLight)))
        XCTAssertLessThan(
            LabelRGB(hex: AccountRailPalette.idleRingDark)
                .contrast(with: LabelRGB(hex: AccountRailPalette.backgroundDark)),
            LabelRGB(hex: AccountRailPalette.glyphDark)
                .contrast(with: LabelRGB(hex: AccountRailPalette.backgroundDark)))
    }

    func testRailIsNarrowAndBandCoversTheWindowButtons() {
        XCTAssertEqual(AccountRailMetrics.width, 64)
        XCTAssertEqual(AccountRailMetrics.bandMinimumWidth, 90)
        XCTAssertGreaterThanOrEqual(AccountRailMetrics.bandMinimumWidth,
                                    AccountRailMetrics.windowButtonsExtent + AccountRailMetrics.windowButtonsMargin)
        XCTAssertGreaterThanOrEqual(AccountRailMetrics.windowButtonsMargin, 8)
    }

    func testBandWidth() {
        // Sidebar on screen: up to its right edge.
        XCTAssertEqual(AccountRailMetrics.bandWidth(sidebarTrailing: 304, sidebarVisible: true), 304)
        // Hidden: still covers the three window buttons.
        XCTAssertEqual(AccountRailMetrics.bandWidth(sidebarTrailing: 304, sidebarVisible: false), 90)
        XCTAssertEqual(AccountRailMetrics.bandWidth(sidebarTrailing: 0, sidebarVisible: true), 90)
    }

    func testCollapsedSidebarStripFillsTheBandStep() {
        typealias M = AccountRailMetrics
        XCTAssertEqual(M.stripWidth, 40)
        XCTAssertEqual(M.stripBandWidth, 104)
        // Collapsed: the band ends where the strip does, rail 64 + strip 40.
        XCTAssertEqual(M.bandWidth(sidebarTrailing: 304, sidebarVisible: false, stripVisible: true), 104)
        // Still covers the window buttons.
        XCTAssertGreaterThanOrEqual(M.stripBandWidth, M.bandMinimumWidth)
        // The largest sidebar glyph (15 pt) fits the capsule with room.
        XCTAssertGreaterThanOrEqual(M.stripItemWidth, 15 + 2 * 8)
        XCTAssertGreaterThanOrEqual(M.stripItemHeight, 24)
        // Full sidebar on screen: the strip changes nothing.
        XCTAssertEqual(M.bandWidth(sidebarTrailing: 304, sidebarVisible: true, stripVisible: false), 304)
    }

    func testBandSpansWindowOnlyCollapsedInLight() {
        typealias M = AccountRailMetrics
        XCTAssertTrue(M.bandSpansWindow(sidebarVisible: false, stripVisible: true, isLight: true))
        // Dark, expanded, and hidden entirely (no strip): as before.
        XCTAssertFalse(M.bandSpansWindow(sidebarVisible: false, stripVisible: true, isLight: false))
        XCTAssertFalse(M.bandSpansWindow(sidebarVisible: true, stripVisible: false, isLight: true))
        XCTAssertFalse(M.bandSpansWindow(sidebarVisible: true, stripVisible: true, isLight: true))
        XCTAssertFalse(M.bandSpansWindow(sidebarVisible: false, stripVisible: false, isLight: true))
        XCTAssertFalse(M.bandSpansWindow(sidebarVisible: false, stripVisible: false, isLight: false))
    }

    func testAddAccountEntryIsShownByDefault() {
        let key = AccountRailMetrics.showAddAccountKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(AccountRailMetrics.showAddAccountDefault)
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
    }
}
