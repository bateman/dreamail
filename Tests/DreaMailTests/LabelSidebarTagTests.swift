import XCTest

/// The sidebar tag of a label with a Gmail color is always a visible fill
/// (never the outline that means "no color"), and the color sheet's
/// "Current:" line states what is stored.
final class LabelSidebarTagTests: XCTestCase {
    private let palette = LabelColorStyleTests.gmailPalette

    /// Every documented background, in both appearances: the tag's fill is
    /// at least `minimumTagDifference` (CIE76) from the sidebar's content
    /// color, keeps its own value when it already is, and is moved only
    /// toward white (dark) or black (light) otherwise.
    func testEveryDocumentedColorIsAVisibleFillInBothAppearances() {
        var moved: [LabelPillStyle.Appearance: [String]] = [.light: [], .dark: []]
        for appearance in LabelPillStyle.Appearance.allCases {
            let surface = LabelPillStyle.surfaceColor(.content, appearance)
            for hex in palette {
                let own = LabelRGB(hexString: hex)!
                let fill = LabelPillStyle.visibleTagFill(own, appearance: appearance)
                XCTAssertGreaterThanOrEqual(fill.difference(from: surface),
                                            LabelPillStyle.minimumTagDifference,
                                            "\(hex) \(appearance)")
                if own.difference(from: surface) >= LabelPillStyle.minimumTagDifference {
                    XCTAssertEqual(fill, own, "\(hex) \(appearance): already visible, unchanged")
                } else {
                    moved[appearance, default: []].append(hex)
                    // Moved away from the surface only.
                    if appearance == .dark {
                        XCTAssertGreaterThan(fill.luminance, own.luminance, hex)
                    } else {
                        XCTAssertLessThan(fill.luminance, own.luminance, hex)
                    }
                }
            }
        }
        // The dark greys, in dark appearance, are what the owner saw as
        // "no color": black and the two dark greys sit within 25 of #191919.
        for hex in ["#000000", "#434343", "#464646"] {
            XCTAssertTrue(moved[.dark]!.contains(hex), "\(hex) is lightened in dark appearance")
        }
        for hex in ["#ffffff", "#f3f3f3", "#efefef", "#e7e7e7"] {
            XCTAssertTrue(moved[.light]!.contains(hex), "\(hex) is darkened in light appearance")
        }
    }

    /// The old rule drew these as a dark fill plus an outline on the dark
    /// sidebar (`needsBorder`); the tag now has a clearly lighter fill.
    func testDarkGreyInDarkAppearanceIsNoLongerOutlineLike() {
        let style = LabelPillStyle.resolve(LabelColors(background: "#434343", text: "#ffffff"),
                                           appearance: .dark, shape: .dot)
        XCTAssertTrue(style.needsBorder, "the dot rule alone would outline it")
        let tag = LabelPillStyle.visibleTagFill(style.fill, appearance: .dark)
        XCTAssertNotEqual(tag, style.fill)
        XCTAssertGreaterThanOrEqual(tag.difference(from: LabelPillStyle.surfaceColor(.content, .dark)), 25)
    }

    // MARK: - "Current:" line

    private let grid = GmailLabelPalette.swatches.map(\.background)

    private func row(gmail: String? = nil, text: String? = nil, local: String? = nil) -> LabelRow {
        LabelRow(id: "a:L", accountId: "a", gmailLabelId: "L", name: "n", type: "user",
                 color: local, gmailBackgroundColor: gmail, gmailTextColor: text)
    }

    func testCurrentLineForAColorOnTheGrid() {
        XCTAssertEqual(LabelCurrentColor.gmail(row(gmail: "#16a766", text: "#ffffff")),
                       "Current: #16a766, text #ffffff")
    }

    func testCurrentLineForAColorOffTheGrid() {
        // In Gmail's 102, not among the 64 swatches.
        XCTAssertFalse(grid.contains("#4986e7"))
        XCTAssertEqual(LabelCurrentColor.gmail(row(gmail: "#4986E7", text: "#000000")),
                       "Current: #4986e7, text #000000 (not in this palette)")
        XCTAssertEqual(LabelCurrentColor.gmail(row(gmail: "#4986e7")),
                       "Current: #4986e7 (not in this palette)")
    }

    func testCurrentLineWithoutAColor() {
        XCTAssertEqual(LabelCurrentColor.gmail(row()), "Current: none")
        XCTAssertEqual(LabelCurrentColor.local(row(), palette: ["#EB5757"]), "Current: none")
    }

    func testCurrentLineForALocalPick() {
        let mac = ["#EB5757", "#F2994A"]
        XCTAssertEqual(LabelCurrentColor.local(row(local: "#eb5757"), palette: mac), "Current: #eb5757")
        XCTAssertEqual(LabelCurrentColor.local(row(local: "#123456"), palette: mac),
                       "Current: #123456 (not in this palette)")
    }

    /// Every documented background gets a line that names it.
    func testCurrentLineNamesEveryDocumentedColor() {
        for hex in palette {
            let line = LabelCurrentColor.gmail(row(gmail: hex))
            XCTAssertTrue(line.hasPrefix("Current: \(hex)"), line)
            XCTAssertEqual(line.contains("(not in this palette)"), !grid.contains(hex), hex)
        }
    }
}
