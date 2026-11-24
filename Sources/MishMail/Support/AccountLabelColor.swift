import AppKit
import Foundation
import GRDB
import SwiftUI

/// The color of an account's label pill ("Personal", "Fund", …) in the
/// account switcher. Local only: stored on the `account` row as `#rrggbb`
/// (`labelColor`, NULL = default), never sent to Google, and gone with the
/// account row when the account is removed.
enum AccountLabelColor {
    /// Hex stand-ins for the system colors `Color.stable(for:)` picks for
    /// the account avatar, in the same order, so the default pill keeps the
    /// avatar's hue. Light-appearance values of the macOS system colors.
    static let defaultPalette: [String] = [
        "#007aff", // blue
        "#af52de", // purple
        "#ff2d55", // pink
        "#ff9500", // orange
        "#30b0c7", // teal
        "#5856d6", // indigo
        "#28cd41", // green
        "#32ade6", // cyan
    ]

    /// The default color for an account: the avatar's hue.
    static func defaultHex(for accountId: String) -> String {
        defaultPalette[Color.stableIndex(for: accountId, count: defaultPalette.count)]
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

    /// The opaque sRGB color for a stored hex (default when malformed).
    static func nsColor(hex: String?, accountId: String) -> NSColor {
        let rgb = LabelRGB(hexString: resolvedHex(stored: hex, accountId: accountId))
            ?? LabelRGB(hex: 0x787774)
        return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }
}
