import AppKit
import SwiftUI
import XCTest

/// The sidebar and list-column header draw every mailbox view Gmail-style:
/// a monochrome outline glyph, the filled variant on the selected row, one
/// neutral tint for all of them. Colour stays where it carries information
/// (Gmail label colours, the starred star in the list), which is pinned too.
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

    // MARK: - The neutral tint

    func testIconTintIsTheSecondaryLabelColour() {
        XCTAssertEqual(Color.mailIcon, Color.secondary)
    }

    func testSecondaryLabelColourIsAchromaticInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let c = try XCTUnwrap(Self.resolve(.secondaryLabelColor, in: name))
            XCTAssertEqual(c.redComponent, c.greenComponent, accuracy: 0.01, "\(name)")
            XCTAssertEqual(c.greenComponent, c.blueComponent, accuracy: 0.01, "\(name)")
        }
    }

    /// WCAG 2.x non-text contrast (1.4.11) asks for 3:1 against the
    /// adjacent background: here the sidebar.
    func testIconTintContrastsWithTheSidebarInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let fg = try XCTUnwrap(Self.resolve(.secondaryLabelColor, in: name))
            let bg = try XCTUnwrap(Self.resolve(.mailSidebar, in: name))
            let ratio = Self.contrast(fg, over: bg)
            XCTAssertGreaterThanOrEqual(ratio, 3.0, "\(name): \(ratio)")
        }
    }

    // MARK: - Wiring in the views

    /// Every place that draws a mailbox view's glyph tints it with the one
    /// neutral token; no view carries its own hue any more.
    func testMailboxGlyphsAreDrawnWithTheNeutralTint() throws {
        var uses = 0
        for file in ["Sources/MishMail/UI/ContentView.swift",
                     "Sources/MishMail/UI/ThreadListView.swift"] {
            let lines = try ForkIdentityTests.repoFile(file)
                .components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("Image(systemName:")
                && (line.contains(".icon(") || line.contains(".icon)")
                    || line.contains(".selectedIcon")) {
                uses += 1
                let next = lines[(i + 1)..<min(i + 3, lines.count)].joined(separator: "\n")
                XCTAssertTrue(next.contains(".foregroundStyle(Color.mailIcon)"),
                              "\(file):\(i + 1) draws a mailbox glyph without the neutral tint")
            }
        }
        // Sidebar row + list-column header.
        XCTAssertGreaterThanOrEqual(uses, 2)
    }

    func testNoPerViewIconColourRemains() throws {
        let root = ForkIdentityTests.repoRoot.appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains(".iconColor"), url.lastPathComponent)
        }
    }

    // MARK: - Colour that carries information stays

    /// Gmail label colours are user data: the organizer palette and the
    /// "#RRGGBB" parsing that renders synced colours are unchanged.
    func testLabelColoursAreUntouched() {
        XCTAssertEqual(Color.labelPalette.map(\.hex), [
            "#EB5757", "#F2994A", "#DFAB01", "#27AE60", "#12A594", "#2D9CDB",
            "#5E6AD2", "#9B51E0", "#E255A1", "#9F6B53", "#787774",
        ])
        for entry in Color.labelPalette {
            let value = UInt32(entry.hex.dropFirst(), radix: 16)!
            XCTAssertEqual(Color.hexString(entry.hex), Color.hex(value), entry.name)
            XCTAssertNotEqual(Color.hexString(entry.hex), Color.mailIcon, entry.name)
        }
    }

    /// Gmail shows a starred conversation's star in yellow in the list.
    func testStarredThreadRowKeepsItsYellowStar() throws {
        let text = try ForkIdentityTests.repoFile("Sources/MishMail/UI/ThreadListView.swift")
        XCTAssertTrue(text.contains("""
                        if thread.isStarred {
                            Image(systemName: "star.fill")
                                .font(.system(size: 12 * fontScale)).foregroundStyle(.yellow)
                        """))
    }

    // MARK: - Helpers

    private static func resolve(_ color: NSColor, in name: NSAppearance.Name) -> NSColor? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var out: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB)
        }
        return out
    }

    /// Contrast ratio of `fg` alpha-composited over the opaque `bg`.
    private static func contrast(_ fg: NSColor, over bg: NSColor) -> Double {
        let a = Double(fg.alphaComponent)
        func mix(_ f: CGFloat, _ b: CGFloat) -> Double { Double(f) * a + Double(b) * (1 - a) }
        let top = (mix(fg.redComponent, bg.redComponent),
                   mix(fg.greenComponent, bg.greenComponent),
                   mix(fg.blueComponent, bg.blueComponent))
        let back = (Double(bg.redComponent), Double(bg.greenComponent), Double(bg.blueComponent))
        let l1 = luminance(top), l2 = luminance(back)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private static func luminance(_ c: (Double, Double, Double)) -> Double {
        func lin(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
    }
}
