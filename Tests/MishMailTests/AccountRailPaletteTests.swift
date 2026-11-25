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

    func testRailCoversTheWindowButtonsWithAMargin() {
        XCTAssertEqual(AccountRail.width, 80)
        XCTAssertGreaterThanOrEqual(AccountRail.width,
                                    AccountRail.windowButtonsExtent + AccountRail.windowButtonsMargin)
        XCTAssertGreaterThanOrEqual(AccountRail.windowButtonsMargin, 8)
    }

    func testAddAccountEntryIsShownByDefault() {
        let key = AccountRail.showAddAccountKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(AccountRail.showAddAccountDefault)
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
    }
}
