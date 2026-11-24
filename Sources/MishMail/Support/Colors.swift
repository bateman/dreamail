import SwiftUI
import AppKit

extension NSColor {
    static let mailAccent = adaptive(light: 0x2383E2, dark: 0x2E9BE8)
    static let mailSidebar = adaptive(light: 0xF7F7F5, dark: 0x232323)

    /// Theme-adaptive color from light/dark sRGB hex values.
    static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        }
    }
}

extension Color {
    // MARK: App palette
    // Warm near-blacks in dark mode, warm off-whites in light mode, and the
    // blue accent. Everything theme-adaptive via NSColor providers.

    /// The blue accent, used everywhere the app previously used the system accent.
    static let mailAccent = Color(nsColor: NSColor.mailAccent)
    /// Main content background (thread list, reading pane).
    static let mailContent = Color(nsColor: .adaptive(light: 0xFFFFFF, dark: 0x191919))
    /// Sidebar background, a step warmer/lighter than the content.
    static let mailSidebar = Color(nsColor: NSColor.mailSidebar)

    /// Opaque color from an sRGB hex value (same in light and dark).
    static func hex(_ hex: UInt32) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    /// Color from a "#RRGGBB" (or "RRGGBB") string; nil when malformed.
    static func hexString(_ string: String) -> Color? {
        var hex = string.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return .hex(value)
    }

    /// The label color palette offered in the organizer (name, hex).
    /// Muted hues that read well as tinted pills in both themes.
    static let labelPalette: [(name: String, hex: String)] = [
        ("Red", "#EB5757"), ("Orange", "#F2994A"), ("Yellow", "#DFAB01"),
        ("Green", "#27AE60"), ("Teal", "#12A594"), ("Blue", "#2D9CDB"),
        ("Indigo", "#5E6AD2"), ("Purple", "#9B51E0"), ("Pink", "#E255A1"),
        ("Brown", "#9F6B53"), ("Gray", "#787774"),
    ]

    /// Deterministic pleasant color for a string (sender avatars, etc.).
    static func stable(for string: String) -> Color {
        var hash: UInt64 = 5381
        for byte in string.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .cyan]
        return palette[Int(hash % UInt64(palette.count))]
    }

    /// Gmail-style category accent colors.
    static func category(_ id: String) -> Color {
        switch id {
        case "CATEGORY_PROMOTIONS": return .green
        case "CATEGORY_SOCIAL": return .blue
        case "CATEGORY_UPDATES": return .orange
        case "CATEGORY_FORUMS": return .purple
        default: return .gray
        }
    }

    /// Accent for an on-device AI triage bucket (Classifier.categories).
    static func aiCategory(_ name: String) -> Color {
        switch name {
        case "Reply needed": return .red
        case "FYI": return .blue
        case "Newsletter": return .purple
        case "Receipt": return .teal
        default: return .gray
        }
    }
}

/// Glyphs per mailbox view, Gmail-style: every view is a monochrome outline
/// symbol, and the selected row swaps in the filled variant. No view has a
/// hue of its own — colour in the sidebar is reserved for what carries
/// information (Gmail label colours, unread badges, warnings, selection).
/// Used by the sidebar and the list-column header.
extension MailboxView {
    /// Outline glyph, shown on unselected rows.
    var icon: String {
        switch self {
        case .inbox: return "tray"
        case .promotions: return "basket"
        case .social: return "bubble.left"
        case .starred: return "star"
        case .snoozed: return "clock"
        case .reminders: return "bell"
        case .drafts: return "doc.text"
        case .scheduled: return "calendar.badge.clock"
        case .outbox: return "tray.and.arrow.up"
        case .sent: return "paperplane"
        case .allMail: return "archivebox"
        case .trash: return "trash"
        case .account: return "person.crop.circle"
        case .label, .labels: return "tag"
        case .saved: return "line.3.horizontal.decrease.circle"
        }
    }

    /// Filled glyph, shown on the selected row (and the list-column header,
    /// which names the selected view). Falls back to the outline where the
    /// symbol has no filled form.
    var selectedIcon: String {
        switch self {
        // No filled variant of the badged calendar: keep the outline.
        case .scheduled: return icon
        default: return icon + ".fill"
        }
    }

    func icon(selected: Bool) -> String { selected ? selectedIcon : icon }
}

extension Color {
    /// The one tint for navigation glyphs (sidebar rows, "Add view", the
    /// list-column header): the secondary label colour, so it follows the
    /// text and adapts to light/dark and Increase Contrast.
    static let mailIcon = Color.secondary
}
