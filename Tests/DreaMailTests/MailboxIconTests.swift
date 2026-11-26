import AppKit
import XCTest

/// The sidebar and list-column header draw every mailbox view Gmail-style:
/// a monochrome outline glyph, the filled variant on the selected row, in
/// neutral tints that contrast with their backgrounds. The starred star in
/// the list keeps its colour, which is pinned too.
final class MailboxIconTests: XCTestCase {

    /// One instance of every `MailboxView` case, with its outline and filled
    /// symbol names.
    private static let table: [(view: MailboxView, outline: String, filled: String)] = [
        (.inbox, "tray", "tray.fill"),
        (.promotions, "basket", "basket.fill"),
        (.social, "bubble.left", "bubble.left.fill"),
        (.starred, "star", "star.fill"),
        (.snoozed, "clock", "clock.fill"),
        (.labels, "tag", "tag.fill"),
        (.reminders, "bell", "bell.fill"),
        (.drafts, "doc.text", "doc.text.fill"),
        // The badged calendar has no filled form: the outline stays.
        (.scheduled, "calendar.badge.clock", "calendar.badge.clock"),
        (.outbox, "tray.and.arrow.up", "tray.and.arrow.up.fill"),
        (.sent, "paperplane", "paperplane.fill"),
        (.allMail, "archivebox", "archivebox.fill"),
        (.trash, "trash", "trash.fill"),
        (.account("ada@example.com"), "person.crop.circle", "person.crop.circle.fill"),
        (.label(account: "ada@example.com", labelId: "Label_1", name: "Work"), "tag", "tag.fill"),
        (.saved(1, "Receipts"), "line.3.horizontal.decrease.circle",
         "line.3.horizontal.decrease.circle.fill"),
    ]

    // MARK: - Glyphs

    func testEveryViewHasAnOutlineAndAFilledGlyph() {
        for row in Self.table {
            XCTAssertEqual(row.view.icon, row.outline, "\(row.view)")
            XCTAssertEqual(row.view.selectedIcon, row.filled, "\(row.view)")
            XCTAssertEqual(row.view.icon(selected: false), row.outline, "\(row.view)")
            XCTAssertEqual(row.view.icon(selected: true), row.filled, "\(row.view)")
            XCTAssertFalse(row.outline.hasSuffix(".fill"),
                           "\(row.view): unselected rows use the outline")
        }
    }

    func testEveryGlyphExistsAsASystemSymbol() {
        for row in Self.table {
            for name in [row.outline, row.filled] {
                XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil),
                                "\(row.view): \(name) is not an SF Symbol on this macOS")
            }
        }
    }

    // MARK: - Contrast

    /// WCAG 2.x non-text contrast (1.4.11) asks for 3:1 against the adjacent
    /// background: the sidebar for unselected rows (secondary label colour),
    /// the selection highlight for the selected row (label colour), which
    /// must also read darker than the unselected rows, as in Gmail.
    func testIconTintsContrastWithTheirBackgroundsInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let sidebar = try XCTUnwrap(Self.resolve(.mailSidebar, in: name))
            let highlight = try XCTUnwrap(
                Self.resolve(.unemphasizedSelectedContentBackgroundColor, in: name))
            let secondary = try XCTUnwrap(Self.resolve(.secondaryLabelColor, in: name))
            let label = try XCTUnwrap(Self.resolve(.labelColor, in: name))
            let selectedBackground = Self.composite(highlight, over: sidebar)

            let unselected = Self.contrast(Self.composite(secondary, over: sidebar), sidebar)
            let selected = Self.contrast(Self.composite(label, over: selectedBackground),
                                         selectedBackground)

            XCTAssertGreaterThanOrEqual(unselected, 3.0, "\(name) unselected: \(unselected)")
            XCTAssertGreaterThanOrEqual(selected, 3.0, "\(name) selected: \(selected)")
            XCTAssertGreaterThan(selected, unselected, "\(name)")
        }
    }

    // MARK: - Colour that carries information stays

    /// Gmail shows a starred conversation's star in yellow in the list.
    /// `inked` keeps it yellow everywhere except on a selection painted in
    /// a custom accent, where a yellow star could vanish (a yellow accent):
    /// there it takes the selection ink like the rest of the row.
    func testStarredThreadRowKeepsItsYellowStar() throws {
        // Compared with whitespace collapsed, so re-indenting the row does
        // not break the guard.
        func squash(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let text = try ForkIdentityTests.repoFile("Sources/DreaMail/UI/ThreadListView.swift")
        XCTAssertTrue(squash(text).contains(squash("""
            Image(systemName: thread.isStarred ? "star.fill" : "star")
                .font(.system(size: 14 * fontScale))
                .foregroundStyle(thread.isStarred ? inked(.yellow) : inked(.secondary, emphasis: 0.8))
            """)))
        // `inked` returns the colour it is given unless the row is the
        // painted selection.
        XCTAssertTrue(squash(text).contains(squash("""
            guard let ink else { return normal }
            """)))
        XCTAssertTrue(squash(text).contains(squash("""
            SelectionInk.color(selected: model.isFocused, prominence: prominence, accent: accent)
            """)))
    }

    // MARK: - Helpers

    private static func resolve(_ color: NSColor, in name: NSAppearance.Name) -> NSColor? {
        AppearanceColorSupport.resolve(color, in: name)
    }

    private typealias RGB = (r: Double, g: Double, b: Double)

    /// `fg` alpha-composited over the opaque `bg`.
    private static func composite(_ fg: NSColor, over bg: RGB) -> RGB {
        let a = Double(fg.alphaComponent)
        return (Double(fg.redComponent) * a + bg.r * (1 - a),
                Double(fg.greenComponent) * a + bg.g * (1 - a),
                Double(fg.blueComponent) * a + bg.b * (1 - a))
    }

    private static func composite(_ fg: NSColor, over bg: NSColor) -> RGB {
        composite(fg, over: (Double(bg.redComponent), Double(bg.greenComponent),
                             Double(bg.blueComponent)))
    }

    private static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let l1 = luminance(a), l2 = luminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private static func contrast(_ a: RGB, _ b: NSColor) -> Double {
        contrast(a, (Double(b.redComponent), Double(b.greenComponent), Double(b.blueComponent)))
    }

    private static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
}
