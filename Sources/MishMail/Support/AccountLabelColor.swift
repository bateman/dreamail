import AppKit
import Foundation
import GRDB
import SwiftUI

/// The color of an account's label pill ("Personal", "Fund", …) in the
/// account switcher. Local only: stored on the `account` row as `#rrggbb`
/// (`labelColor`, NULL = default), never sent to Google, and gone with the
/// account row when the account is removed.
enum AccountLabelColor {
    /// sRGB stand-ins for the system colors `Color.stable(for:)` picks for
    /// the account avatar (`Color.stablePalette`), in the same order, so the
    /// default pill keeps the avatar's hue. The light-appearance values: a
    /// fixed table, so the pill does not change with the appearance. Tests
    /// pin each entry to the system color it stands for (macOS 26 values;
    /// older systems draw the avatar in slightly different shades).
    static let defaultPalette: [UInt32] = [
        0x0088FF, // blue
        0xCB30E0, // purple
        0xFF2D55, // pink
        0xFF8D28, // orange
        0x00C3D0, // teal
        0x6155F5, // indigo
        0x34C759, // green
        0x00C0E8, // cyan
    ]

    static func hex(_ value: UInt32) -> String {
        String(format: "#%06x", value & 0xFFFFFF)
    }

    private static func defaultRGB(for accountId: String) -> LabelRGB {
        LabelRGB(hex: defaultPalette[Color.stableIndex(for: accountId, count: defaultPalette.count)])
    }

    /// The default color for an account: the avatar's hue.
    static func defaultHex(for accountId: String) -> String {
        hex(defaultPalette[Color.stableIndex(for: accountId, count: defaultPalette.count)])
    }

    /// The label the switcher shows as a pill, or nil when it adds nothing:
    /// no sender name (the label is then the title), or a label equal to
    /// the address or the sender name.
    static func pillLabel(displayName: String, senderName: String, accountId: String) -> String? {
        guard !senderName.isEmpty else { return nil }
        guard !displayName.isEmpty, displayName != accountId, displayName != senderName else {
            return nil
        }
        return displayName
    }

    static func pillLabel(_ account: Account) -> String? {
        pillLabel(displayName: account.displayName, senderName: account.senderName,
                  accountId: account.id)
    }

    /// The stored color when it is a valid `#rrggbb`, else the default.
    static func resolvedHex(stored: String?, accountId: String) -> String {
        LabelRGB.normalizedHex(stored) ?? defaultHex(for: accountId)
    }

    /// The pill colors for an account; text is left to `LabelPillStyle`.
    static func colors(for account: Account) -> LabelColors {
        LabelColors(background: resolvedHex(stored: account.labelColor, accountId: account.id),
                    text: nil)
    }

    /// Saves an account's label color. nil, empty or malformed resets it to
    /// the default (NULL), so no arbitrary string is stored.
    static func set(_ db: Database, accountId: String, hex: String?) throws {
        try db.execute(sql: "UPDATE account SET labelColor = ? WHERE id = ?",
                       arguments: [LabelRGB.normalizedHex(hex), accountId])
    }

    // MARK: - Picker conversion

    /// `#rrggbb` for a color from the system color panel: converted to
    /// sRGB, components clamped to 0…1 (wide-gamut colors land on the sRGB
    /// edge), alpha ignored. nil when the color has no RGB form (a pattern).
    static func hex(from color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ c: CGFloat) -> Int {
            guard c.isFinite else { return 0 }
            return Int((min(1, max(0, Double(c))) * 255).rounded())
        }
        return String(format: "#%02x%02x%02x",
                      byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    static func hex(from color: Color) -> String? {
        hex(from: NSColor(color))
    }

    /// What a color picker `set` means for the edit: the new `#rrggbb`, or
    /// nil when it is the color already shown. Opening the color well
    /// echoes the current color back; that must not turn the default into
    /// an explicit pick.
    static func pickedHex(_ color: NSColor, shown shownHex: String) -> String? {
        guard let picked = hex(from: color), picked != LabelRGB.normalizedHex(shownHex) else {
            return nil
        }
        return picked
    }

    static func pickedHex(_ color: Color, shown shownHex: String) -> String? {
        pickedHex(NSColor(color), shown: shownHex)
    }

    /// The opaque sRGB color for a stored hex (default when malformed).
    static func nsColor(hex: String?, accountId: String) -> NSColor {
        let rgb = LabelRGB(hexString: hex) ?? defaultRGB(for: accountId)
        return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }
}
