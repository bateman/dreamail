import AppKit

/// Colour helpers shared by the sidebar glyph tests.
enum AppearanceColorSupport {
    /// `color` resolved to sRGB under the named appearance.
    static func resolve(_ color: NSColor, in name: NSAppearance.Name) -> NSColor? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var out: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB)
        }
        return out
    }
}
