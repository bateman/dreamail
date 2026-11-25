import AppKit
import SwiftUI
import XCTest

/// The sidebar glyphs (main sidebar rows, "Add view", the Settings sidebar)
/// share one style: medium weight at the row title's size for the macOS
/// "Sidebar icon size" setting, and monochrome colours that never resolve
/// to the accent.
final class MailIconStyleTests: XCTestCase {

    // MARK: - Metrics

    func testSizeFollowsTheSidebarIconSizeSetting() {
        let cases: [(SidebarRowSize, CGFloat)] = [(.small, 11), (.medium, 13), (.large, 15)]
        for (rowSize, points) in cases {
            let metrics = MailIconMetrics(rowSize: rowSize)
            XCTAssertEqual(metrics.pointSize, points, "\(rowSize)")
            XCTAssertEqual(metrics.columnWidth, points + 5, "\(rowSize)")
            XCTAssertEqual(metrics.weight, .medium, "\(rowSize)")
        }
    }

    // MARK: - Tint

    /// Concrete label colours, not hierarchical styles: inside a selected
    /// `.sidebar` row a hierarchical `.primary` resolves to the accent.
    func testTintsAreTheLabelColoursAndNotTheAccent() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let selected = try XCTUnwrap(Self.resolve(NSColor(Color.mailIcon(selected: true)), in: name))
            let unselected = try XCTUnwrap(Self.resolve(NSColor(Color.mailIcon(selected: false)), in: name))
            let label = try XCTUnwrap(Self.resolve(.labelColor, in: name))
            let secondary = try XCTUnwrap(Self.resolve(.secondaryLabelColor, in: name))
            let accent = try XCTUnwrap(Self.resolve(.controlAccentColor, in: name))

            XCTAssertTrue(Self.same(selected, label), "\(name) selected: \(selected)")
            XCTAssertTrue(Self.same(unselected, secondary), "\(name) unselected: \(unselected)")
            XCTAssertFalse(Self.same(selected, accent), "\(name)")
            XCTAssertLessThan(Self.saturation(selected), 0.1, "\(name) selected must be grey")
            XCTAssertLessThan(Self.saturation(unselected), 0.1, "\(name) unselected must be grey")
        }
    }

    /// A focused sidebar draws the selection as a solid accent capsule; the
    /// row then draws white on it, as AppKit does, never black or the accent.
    func testEmphasizedSelectionDrawsWhiteOnTheAccent() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let white = try XCTUnwrap(Self.resolve(.alternateSelectedControlTextColor, in: name))
            for selected in [true, false] {
                let icon = try XCTUnwrap(Self.resolve(
                    NSColor(Color.mailIcon(selected: selected, prominence: .increased)), in: name))
                XCTAssertTrue(Self.same(icon, white), "\(name) selected \(selected): \(icon)")
                let plain = try XCTUnwrap(Self.resolve(
                    NSColor(Color.mailIcon(selected: selected, prominence: .standard)), in: name))
                let expected = try XCTUnwrap(Self.resolve(
                    NSColor(Color.mailIcon(selected: selected)), in: name))
                XCTAssertTrue(Self.same(plain, expected), "\(name) selected \(selected)")
            }
            let title = try XCTUnwrap(Self.resolve(NSColor(Color.mailRowTitle(prominence: .increased)), in: name))
            XCTAssertTrue(Self.same(title, white), "\(name) title: \(title)")
            let plainTitle = try XCTUnwrap(Self.resolve(NSColor(Color.mailRowTitle(prominence: .standard)), in: name))
            let label = try XCTUnwrap(Self.resolve(.labelColor, in: name))
            XCTAssertTrue(Self.same(plainTitle, label), "\(name) title: \(plainTitle)")
            XCTAssertLessThan(Self.saturation(white), 0.1, "\(name)")
        }
    }

    // MARK: - Every sidebar glyph uses the shared style

    /// The list-column header keeps the toolbar's own symbol size and only
    /// takes the monochrome colour, so it is not listed here.
    func testSidebarGlyphsUseTheSharedStyle() throws {
        for path in ["Sources/DreaMail/UI/ContentView.swift", "Sources/DreaMail/UI/SettingsView.swift"] {
            let text = try ForkIdentityTests.repoFile(path)
            XCTAssertTrue(text.contains(".mailIconStyle("), path)
            XCTAssertTrue(text.contains(".mailRowTitleStyle()"), path)
            XCTAssertFalse(text.contains(".foregroundStyle(.mailIcon("), path)
        }
    }

    // MARK: - Helpers

    private static func resolve(_ color: NSColor, in name: NSAppearance.Name) -> NSColor? {
        AppearanceColorSupport.resolve(color, in: name)
    }

    private static func same(_ a: NSColor, _ b: NSColor) -> Bool {
        abs(a.redComponent - b.redComponent) < 0.01
            && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
            && abs(a.alphaComponent - b.alphaComponent) < 0.01
    }

    private static func saturation(_ c: NSColor) -> CGFloat {
        let hi = max(c.redComponent, c.greenComponent, c.blueComponent)
        let lo = min(c.redComponent, c.greenComponent, c.blueComponent)
        return hi == 0 ? 0 : (hi - lo) / hi
    }
}
