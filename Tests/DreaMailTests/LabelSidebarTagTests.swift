import XCTest
import AppKit

/// The sidebar tag of a label with a Gmail color is always a visible fill
/// (never the outline that means "no color"), and the color sheet's
/// "Current:" line states what is stored.
final class LabelSidebarTagTests: XCTestCase {
    private let palette = LabelColorStyleTests.gmailPalette

    private func tag(_ hex: String?, _ appearance: LabelPillStyle.Appearance) -> SidebarTagStyle {
        SidebarTagStyle.resolve(LabelColors(background: hex, text: nil), appearance: appearance)
    }

    /// The tag is measured against the sidebar's own background, the same
    /// constant the sidebar is painted with.
    func testSidebarSurfaceIsTheSidebarColor() throws {
        for (appearance, name) in [(LabelPillStyle.Appearance.light, NSAppearance.Name.aqua),
                                   (.dark, .darkAqua)] {
            let c = try XCTUnwrap(AppearanceColorSupport.resolve(.mailSidebar, in: name))
            XCTAssertEqual(LabelPillStyle.sidebarSurface(appearance).r, Double(c.redComponent), accuracy: 0.002)
            XCTAssertEqual(LabelPillStyle.sidebarSurface(appearance).b, Double(c.blueComponent), accuracy: 0.002)
        }
    }

    /// Dark appearance, every documented background: the fill is at least
    /// `minimumTagDifference` (CIE76) from the sidebar background, no
    /// outline, unchanged when it already is, otherwise only lightened.
    func testEveryDocumentedColorIsAVisibleFillInDarkAppearance() throws {
        let surface = LabelPillStyle.sidebarSurface(.dark)
        var moved: [String] = []
        for hex in palette {
            let own = LabelRGB(hexString: hex)!
            let style = tag(hex, .dark)
            let fill = try XCTUnwrap(style.fill)
            XCTAssertNil(style.outline, hex)
            XCTAssertGreaterThanOrEqual(fill.difference(from: surface),
                                        LabelPillStyle.minimumTagDifference, hex)
            if own.difference(from: surface) >= LabelPillStyle.minimumTagDifference {
                XCTAssertEqual(fill, own, "\(hex): already visible, unchanged")
            } else {
                moved.append(hex)
                XCTAssertGreaterThan(fill.luminance, own.luminance, hex)
            }
        }
        // The dark greys are what the owner saw as "no color".
        for hex in ["#000000", "#434343", "#464646"] {
            XCTAssertTrue(moved.contains(hex), "\(hex) is lightened in dark appearance")
        }
    }

    /// Light appearance is drawn as before: the true fill, with the dot
    /// rule's outline where it asks for one.
    func testLightAppearanceKeepsTheTrueFill() {
        for hex in palette {
            let colors = LabelColors(background: hex, text: nil)
            let old = LabelPillStyle.resolve(colors, appearance: .light, shape: .dot)
            let style = SidebarTagStyle.resolve(colors, appearance: .light)
            XCTAssertEqual(style.fill, LabelRGB(hexString: hex), hex)
            XCTAssertEqual(style.outline != nil, old.needsBorder, hex)
            if old.needsBorder { XCTAssertEqual(style.outline, old.border, hex) }
        }
    }

    /// Dark grey, a pastel and no color, in both appearances.
    func testDarkGreyPastelAndNoColor() {
        let darkGrey = tag("#434343", .dark)
        XCTAssertNotEqual(darkGrey.fill, LabelRGB(hexString: "#434343"))
        XCTAssertNil(darkGrey.outline)
        XCTAssertEqual(tag("#434343", .light).fill, LabelRGB(hexString: "#434343"))
        let pastel = tag("#fef1d1", .light)
        XCTAssertEqual(pastel.fill, LabelRGB(hexString: "#fef1d1"))
        XCTAssertNotNil(pastel.outline, "a pastel keeps its thin outline, as before")
        XCTAssertEqual(tag("#fef1d1", .dark).fill, LabelRGB(hexString: "#fef1d1"))
        for appearance in LabelPillStyle.Appearance.allCases {
            for none in [nil, "", "oops"] {
                let style = tag(none, appearance)
                XCTAssertNil(style.fill)
                XCTAssertNotNil(style.outline, "no color is the outline only")
            }
        }
    }

    // MARK: - What a label is drawn with

    private func row(gmail: String? = nil, text: String? = nil, local: String? = nil) -> LabelRow {
        LabelRow(id: "a:L", accountId: "a", gmailLabelId: "L", name: "n", type: "user",
                 color: local, gmailBackgroundColor: gmail, gmailTextColor: text)
    }

    func testAColorOnTheGridIsDrawnAsGmailSentIt() {
        XCTAssertEqual(row(gmail: "#16a766", text: "#ffffff").displayColors,
                       LabelColors(background: "#16a766", text: "#ffffff"))
    }

    func testAColorOffTheGridIsDrawnAsGmailSentIt() {
        // In Gmail's 102, not among the 64 swatches.
        XCTAssertFalse(GmailLabelPalette.swatches.map(\.background).contains("#4986e7"))
        XCTAssertEqual(row(gmail: "#4986e7", text: "#000000").displayColors,
                       LabelColors(background: "#4986e7", text: "#000000"))
        XCTAssertEqual(row(gmail: "#4986e7").displayColors.background, "#4986e7")
    }

    func testWithoutAColorNothingIsDrawn() {
        XCTAssertEqual(row().displayColors, .none)
    }

    /// The Mac-only column is not read: it neither draws nor hides Gmail's color.
    func testALocalPickIsNotDrawn() {
        XCTAssertEqual(row(local: "#eb5757").displayColors, .none)
        XCTAssertEqual(row(gmail: "#16a766", text: "#ffffff", local: "#123456").displayColors,
                       LabelColors(background: "#16a766", text: "#ffffff"))
    }

    /// Every documented background is drawn with itself.
    func testEveryDocumentedColorIsDrawnWithItsBackground() {
        for hex in palette {
            XCTAssertEqual(LabelRGB.normalizedHex(row(gmail: hex).displayColors.background),
                           LabelRGB.normalizedHex(hex), hex)
        }
    }
}
