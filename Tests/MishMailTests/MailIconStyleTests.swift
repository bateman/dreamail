import AppKit
import SwiftUI
import XCTest

/// The navigation glyphs (sidebar rows, "Add view", the Settings sidebar,
/// the list-column header) share one style: the default, not rounded, font
/// design, medium weight, the row title's size, and monochrome label
/// colours that never resolve to the accent.
final class MailIconStyleTests: XCTestCase {

    // MARK: - Metrics

    func testDefaultScaleMatchesTheSidebarRowTitle() {
        let metrics = MailIconMetrics()
        XCTAssertEqual(metrics.design, .default)
        XCTAssertNotEqual(metrics.design, .rounded)
        XCTAssertEqual(metrics.weight, .medium)
        XCTAssertEqual(metrics.pointSize, 13)
        XCTAssertEqual(metrics.columnWidth, 18)
    }

    /// The Text size steps of `AppFontScale.options` (App/, not compiled
    /// into this bundle).
    private static let fontScales: [CGFloat] = [0.8, 0.9, 1.0, 1.15, 1.3, 1.45, 1.6]

    func testEveryFontScaleKeepsTheDesignAndWeightAndScalesTheSize() {
        for scale in Self.fontScales {
            let metrics = MailIconMetrics(scale: scale)
            XCTAssertEqual(metrics.design, .default, "\(scale)")
            XCTAssertEqual(metrics.weight, .medium, "\(scale)")
            XCTAssertEqual(metrics.pointSize, 13 * scale, accuracy: 0.0001, "\(scale)")
            XCTAssertEqual(metrics.columnWidth, 18 * scale, accuracy: 0.0001, "\(scale)")
            XCTAssertEqual(metrics, MailIconMetrics(scale: scale))
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

    // MARK: - Every navigation glyph uses the shared style

    func testNavigationGlyphsUseTheSharedStyle() throws {
        let content = try Self.squashed("Sources/MishMail/UI/ContentView.swift")
        XCTAssertTrue(content.contains(Self.squash("""
            Image(systemName: view.icon(selected: selected))
                .mailIconStyle(selected: selected)
            }
            .listItemTint(.monochrome)
            """)), "sidebar rows")
        XCTAssertTrue(content.contains(Self.squash("""
            Image(systemName: "plus")
                .mailIconStyle(selected: false)
            """)), "Add view")

        let settings = try Self.squashed("Sources/MishMail/UI/SettingsView.swift")
        XCTAssertTrue(settings.contains(Self.squash("""
            Image(systemName: p.icon).mailIconStyle(selected: pane == p)
            }
            .listItemTint(.monochrome)
            """)), "Settings sidebar")

        let list = try Self.squashed("Sources/MishMail/UI/ThreadListView.swift")
        XCTAssertTrue(list.contains(Self.squash("""
            Image(systemName: store.selectedView.selectedIcon)
                .mailIconStyle(selected: false)
            """)), "list-column header")

        // No rounded design on any of these views.
        for text in [content, settings, list] {
            XCTAssertFalse(text.contains(".fontDesign(.rounded)"))
        }
    }

    // MARK: - Helpers

    private static func squash(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func squashed(_ path: String) throws -> String {
        squash(try ForkIdentityTests.repoFile(path))
    }

    private static func resolve(_ color: NSColor, in name: NSAppearance.Name) -> NSColor? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var out: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB)
        }
        return out
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
