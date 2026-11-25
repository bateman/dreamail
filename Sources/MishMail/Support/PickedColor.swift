import AppKit
import SwiftUI

/// Converting what the system colour picker (`ColorPicker`, the shared
/// `NSColorPanel`) hands back into a stored `#rrggbb`. Shared by every
/// colour setting: account label colours and the app accent.
enum PickedColor {
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

    /// The system color panel is shared and outlives the view that opened
    /// it: close it when that view goes away so it does not linger over
    /// the app (and keep writing into a setting nobody is looking at).
    @MainActor static func closeSharedPanel() {
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.close() }
    }
}
