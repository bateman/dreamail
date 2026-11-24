import Foundation

/// An opaque sRGB color, components in 0…1.
struct LabelRGB: Equatable, Hashable, Sendable {
    let r: Double
    let g: Double
    let b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255,
                  g: Double((hex >> 8) & 0xFF) / 255,
                  b: Double(hex & 0xFF) / 255)
    }

    /// Parses `#RRGGBB` / `RRGGBB` (any case); nil when missing or malformed.
    init?(hexString: String?) {
        guard var hex = hexString?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else {
            return nil
        }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let value = UInt32(hex, radix: 16) else { return nil }
        self.init(hex: value)
    }

    /// `#rrggbb` (lowercase) for a valid 6-digit hex color, with or
    /// without `#` and surrounding spaces; nil for anything else, so no
    /// arbitrary string from the API is stored.
    static func normalizedHex(_ string: String?) -> String? {
        guard var hex = string?.trimmingCharacters(in: .whitespaces) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return "#" + hex.lowercased()
    }

    static let black = LabelRGB(hex: 0x000000)
    static let white = LabelRGB(hex: 0xFFFFFF)

    /// WCAG 2 relative luminance.
    var luminance: Double {
        func channel(_ c: Double) -> Double {
            let x = min(1, max(0, c))
            return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// WCAG 2 contrast ratio between two opaque colors (1…21).
    func contrast(with other: LabelRGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `top` drawn at `alpha` over this color.
    func composited(under top: LabelRGB, alpha: Double) -> LabelRGB {
        LabelRGB(r: top.r * alpha + r * (1 - alpha),
                 g: top.g * alpha + g * (1 - alpha),
                 b: top.b * alpha + b * (1 - alpha))
    }
}

/// A label's colors as Gmail (or the user's local pick) gives them:
/// `#RRGGBB` strings, nil when the label has no color.
struct LabelColors: Equatable, Hashable, Sendable {
    var background: String?
    var text: String?

    static let none = LabelColors(background: nil, text: nil)
}

/// How a label pill (or dot) is drawn: a solid fill, a text color that is
/// readable on it, and whether it needs a thin neutral outline to stand
/// out from the surface behind it. One pure rule for every place a label
/// color is shown (thread rows, reading pane, filter and organizer dots).
struct LabelPillStyle: Equatable, Sendable {
    enum Appearance: Sendable, CaseIterable { case light, dark }

    /// What the pill sits on.
    enum Surface: Sendable, CaseIterable {
        /// Plain content background (unread rows, reading pane, popovers).
        case content
        /// A read row: the list draws a 5% primary-color wash behind it.
        case readRow
        /// The focused row on the system selection highlight.
        case selection
    }

    let fill: LabelRGB
    let text: LabelRGB
    let needsBorder: Bool
    /// Outline color; only drawn when `needsBorder`.
    let border: LabelRGB

    /// WCAG AA for normal-size text.
    static let minimumTextContrast = 4.5
    /// Below this fill-to-surface contrast the pill gets an outline.
    static let minimumEdgeContrast = 1.5

    /// Neutral fill for labels without a color (Gmail's default chip grey).
    static func neutralFill(_ appearance: Appearance) -> LabelRGB {
        appearance == .light ? LabelRGB(hex: 0xDDDDDD) : LabelRGB(hex: 0x3C3C3C)
    }

    /// Approximate opaque color behind a pill. Content backgrounds match
    /// `Color.mailContent`; read rows add the list's 5% primary wash; the
    /// selection is the system blue list highlight (see `surfaceColors`
    /// for the inactive-window grey).
    static func surfaceColor(_ surface: Surface, _ appearance: Appearance) -> LabelRGB {
        surfaceColors(surface, appearance)[0]
    }

    /// Every color the surface can take. The selection highlight is blue
    /// in a key window and grey when the window is inactive; a pill must
    /// stand out on both.
    static func surfaceColors(_ surface: Surface, _ appearance: Appearance) -> [LabelRGB] {
        let content = appearance == .light ? LabelRGB(hex: 0xFFFFFF) : LabelRGB(hex: 0x191919)
        switch surface {
        case .content:
            return [content]
        case .readRow:
            let primary = appearance == .light ? LabelRGB.black : LabelRGB.white
            return [content.composited(under: primary, alpha: readRowWashOpacity)]
        case .selection:
            return appearance == .light
                ? [LabelRGB(hex: 0x0064E1), LabelRGB(hex: 0xDCDCDC)]
                : [LabelRGB(hex: 0x0058D0), LabelRGB(hex: 0x464646)]
        }
    }

    /// Opacity of the read-row wash (`ThreadListView` listRowBackground).
    static let readRowWashOpacity = 0.05

    /// The style for a label's colors on a surface.
    ///
    /// - Fill: the label's background color, solid; neutral grey when it
    ///   has none (or it is malformed).
    /// - Text: the label's own text color when it reaches 4.5:1 on the
    ///   fill, else black or white, whichever contrasts more (one of the
    ///   two always reaches 4.58:1).
    /// - Border: when the fill is within 1.5:1 of the surface (of any of
    ///   its colors), a neutral outline that contrasts with every color of
    ///   the surface by at least 3:1.
    static func resolve(_ colors: LabelColors,
                        appearance: Appearance,
                        surface: Surface = .content) -> LabelPillStyle {
        let ownFill = LabelRGB(hexString: colors.background)
        let fill = ownFill ?? neutralFill(appearance)
        let text: LabelRGB
        // The label's text color only belongs with its own background.
        if ownFill != nil, let own = LabelRGB(hexString: colors.text),
           own.contrast(with: fill) >= minimumTextContrast {
            text = own
        } else {
            text = fill.contrast(with: .black) >= fill.contrast(with: .white) ? .black : .white
        }
        let behind = surfaceColors(surface, appearance)
        let needsBorder = behind.contains { fill.contrast(with: $0) < minimumEdgeContrast }
        return LabelPillStyle(fill: fill, text: text, needsBorder: needsBorder,
                              border: borderColor(on: behind))
    }

    /// Mid grey where it reaches 3:1 against every surface color (white,
    /// dark and read rows); otherwise black or white, whichever has the
    /// larger worst-case contrast (the selection, blue or inactive grey).
    static func borderColor(on surfaces: [LabelRGB]) -> LabelRGB {
        func worst(_ c: LabelRGB) -> Double { surfaces.map { c.contrast(with: $0) }.min() ?? 21 }
        let grey = LabelRGB(hex: 0x808080)
        if worst(grey) >= 3 { return grey }
        return worst(.white) >= worst(.black) ? .white : .black
    }
}
