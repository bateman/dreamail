import AppKit
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

    /// CIELAB (D65) coordinates, for color differences.
    var lab: (l: Double, a: Double, b: Double) {
        func linear(_ c: Double) -> Double {
            let x = min(1, max(0, c))
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let lr = linear(r), lg = linear(g), lb = linear(b)
        let x = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.95047
        let y = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
        let z = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.08883
        func f(_ t: Double) -> Double {
            t > 216.0 / 24389 ? pow(t, 1.0 / 3) : (24389.0 / 27 * t + 16) / 116
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIE76 color difference (Euclidean distance in CIELAB). Unlike the
    /// WCAG ratio it counts hue: a pale yellow on a light grey of the same
    /// luminance is a ratio of 1.0:1 but a difference of 17.
    func difference(from other: LabelRGB) -> Double {
        let p = lab, q = other.lab
        let dl = p.l - q.l, da = p.a - q.a, db = p.b - q.b
        return (dl * dl + da * da + db * db).squareRoot()
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

    /// Whether there is a background color to draw: any valid color means
    /// the label has one; only its absence means "no color".
    var isColored: Bool { LabelRGB(hexString: background) != nil }
}

/// How a label chip (or dot) is drawn: a solid fill, a text color that is
/// readable on it, and whether it needs a thin neutral outline because the
/// fill would otherwise be practically invisible on the surface behind it.
/// Like Gmail, chips normally have no outline. One pure rule for every
/// place a label color is shown (thread rows, reading pane, filter and
/// organizer dots).
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
    /// What is drawn: a chip carries text that outlines it; a dot is a
    /// small swatch with nothing else to carry its edge.
    enum Shape: Sendable { case chip, dot }

    /// Below this fill-to-surface difference (CIE76) a chip gets an
    /// outline. Measured as a color difference, not a WCAG ratio: Gmail's
    /// pale colors are as light as the read-row wash (#fef1d1 is 1.00:1 on
    /// it) and still stand out by hue (difference 17). At 5 only the
    /// near-white greys get an outline on light rows: #ffffff (0) and
    /// #f3f3f3 (4.2) on white; on the wash also #efefef (1.1) and #e7e7e7
    /// (3.9). Every other Gmail color is at least 5.5 away on white and 9.1
    /// on the wash; on dark rows the closest is black (8.8).
    static let minimumEdgeDifference = 5.0
    /// The same for dots (filter list, picker, organizer): an 8-9 pt pale
    /// swatch needs its outline. 25 keeps it for Gmail's pastel row
    /// (#fef1d1 17.7, #e4d7f5 20.4, #c9daf8 21.2 …) and the light greys.
    static let minimumDotEdgeDifference = 25.0
    /// On the selection highlight a chip also needs this WCAG ratio:
    /// CIE76 overstates differences between saturated blues (#285bac on the
    /// dark highlight #0058D0 is 23.8 apart but 1.04:1, same lightness and
    /// hue). The owner's "no outline" is about normal rows.
    static let minimumSelectionContrast = 1.5

    static func minimumEdgeDifference(_ shape: Shape) -> Double {
        shape == .chip ? minimumEdgeDifference : minimumDotEdgeDifference
    }

    /// Whether `fill` is visible on `color` (one color of `surface`)
    /// without an outline.
    static func fillStandsOut(_ fill: LabelRGB, on color: LabelRGB,
                              surface: Surface = .content, shape: Shape = .chip) -> Bool {
        guard fill.difference(from: color) >= minimumEdgeDifference(shape) else { return false }
        return surface != .selection || fill.contrast(with: color) >= minimumSelectionContrast
    }

    /// Neutral fill for labels without a color: Gmail's light grey chip,
    /// and a matching dark grey. #dddddd is 11.9 from white and 7.5 from the
    /// light read-row wash; #3c3c3c is 16.6 from the dark content and 10.9
    /// from the dark wash: no outline on any row except the selection.
    static func neutralFill(_ appearance: Appearance) -> LabelRGB {
        appearance == .light ? LabelRGB(hex: 0xDDDDDD) : LabelRGB(hex: 0x3C3C3C)
    }

    /// Text on the neutral fill: Gmail's dark grey (7.2:1 on #dddddd), and
    /// a light grey in dark mode (7.2:1 on #3c3c3c).
    static func neutralText(_ appearance: Appearance) -> LabelRGB {
        appearance == .light ? LabelRGB(hex: 0x444444) : LabelRGB(hex: 0xD0D0D0)
    }

    /// Approximate opaque color behind a pill. Content backgrounds match
    /// `Color.mailContent`; read rows add the list's 5% primary wash; the
    /// selection is the list highlight: the custom accent when one is set
    /// (`selectionFill`), else the system blue (see `surfaceColors` for the
    /// inactive-window grey).
    static func surfaceColor(_ surface: Surface, _ appearance: Appearance,
                             selectionFill: LabelRGB? = nil) -> LabelRGB {
        surfaceColors(surface, appearance, selectionFill: selectionFill)[0]
    }

    /// The system list highlight (default accent) in a key window.
    static func systemSelection(_ appearance: Appearance) -> LabelRGB {
        appearance == .light ? LabelRGB(hex: 0x0064E1) : LabelRGB(hex: 0x0058D0)
    }

    /// The unemphasized (inactive window, or list without focus) highlight.
    static func inactiveSelection(_ appearance: Appearance) -> LabelRGB {
        appearance == .light ? LabelRGB(hex: 0xDCDCDC) : LabelRGB(hex: 0x464646)
    }

    /// Every color the surface can take. The selection highlight is the
    /// accent in a key window and grey when the window is inactive; a pill
    /// must stand out on both. `selectionFill` is the custom accent the app
    /// draws its selection in, nil for the system highlight.
    static func surfaceColors(_ surface: Surface, _ appearance: Appearance,
                              selectionFill: LabelRGB? = nil) -> [LabelRGB] {
        let content = appearance == .light ? LabelRGB(hex: 0xFFFFFF) : LabelRGB(hex: 0x191919)
        switch surface {
        case .content:
            return [content]
        case .readRow:
            let primary = appearance == .light ? LabelRGB.black : LabelRGB.white
            return [content.composited(under: primary, alpha: readRowWashOpacity)]
        case .selection:
            return [selectionFill ?? systemSelection(appearance), inactiveSelection(appearance)]
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
    ///   two always reaches 4.58:1). The neutral chip uses `neutralText`.
    /// - Border: only when the fill is practically invisible on the
    ///   surface (`fillStandsOut` fails for any of its colors), a neutral
    ///   outline (`borderColor`): 3:1 against every color of the surface
    ///   where one neutral reaches that; on a selection whose two colors
    ///   (a light custom accent and the dark inactive grey, say) leave no
    ///   neutral at 3:1 on both, the black or white with the better worst
    ///   case.
    static func resolve(_ colors: LabelColors,
                        appearance: Appearance,
                        surface: Surface = .content,
                        shape: Shape = .chip,
                        selectionFill: LabelRGB? = nil) -> LabelPillStyle {
        let ownFill = LabelRGB(hexString: colors.background)
        let fill = ownFill ?? neutralFill(appearance)
        let text: LabelRGB
        // The label's text color only belongs with its own background.
        if ownFill == nil {
            text = neutralText(appearance)
        } else if let own = LabelRGB(hexString: colors.text),
                  own.contrast(with: fill) >= minimumTextContrast {
            text = own
        } else {
            text = fill.contrast(with: .black) >= fill.contrast(with: .white) ? .black : .white
        }
        let behind = surfaceColors(surface, appearance, selectionFill: selectionFill)
        let needsBorder = behind.contains {
            !fillStandsOut(fill, on: $0, surface: surface, shape: shape)
        }
        return LabelPillStyle(fill: fill, text: text, needsBorder: needsBorder,
                              border: borderColor(on: behind))
    }

    /// In dark appearance a sidebar tag must read as colored, never as the
    /// outline that means "no color". Below this fill-to-sidebar difference
    /// (CIE76, the dots' value) the fill is moved away from the sidebar (see
    /// `SidebarTagStyle`). Light appearance is not touched.
    static let minimumTagDifference = minimumDotEdgeDifference

    /// The sidebar background (`NSColor.mailSidebar`) as the tag sees it.
    static func sidebarSurface(_ appearance: Appearance) -> LabelRGB {
        var out = appearance == .dark ? LabelRGB(hex: 0x232323) : LabelRGB(hex: 0xF7F7F5)
        let name: NSAppearance.Name = appearance == .dark ? .darkAqua : .aqua
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            if let c = NSColor.mailSidebar.usingColorSpace(.sRGB) {
                out = LabelRGB(r: Double(c.redComponent), g: Double(c.greenComponent),
                               b: Double(c.blueComponent))
            }
        }
        return out
    }

    /// Mid grey where it reaches 3:1 against every surface color (white,
    /// dark and read rows); otherwise black or white, whichever has the
    /// larger worst-case contrast (the selection, blue or inactive grey).
    /// That fallback can stay under 3:1 on one of the two selection colors
    /// when they are far apart in lightness (a pale custom accent in dark
    /// mode against the inactive grey).
    static func borderColor(on surfaces: [LabelRGB]) -> LabelRGB {
        func worst(_ c: LabelRGB) -> Double { surfaces.map { c.contrast(with: $0) }.min() ?? 21 }
        let grey = LabelRGB(hex: 0x808080)
        if worst(grey) >= 3 { return grey }
        return worst(.white) >= worst(.black) ? .white : .black
    }
}

/// How the sidebar's label tag is drawn, in one pure rule the view and the
/// tests share.
///
/// - No color: the outline only (`border`), as Gmail draws it.
/// - Light appearance: exactly the label's fill, with an outline where
///   `LabelPillStyle` asks for one (a pale pastel keeps its true color).
/// - Dark appearance: the label's fill, mixed toward white in 1% steps only
///   as far as needed to be `minimumTagDifference` (25) from the sidebar
///   background, no outline; a fill already that far is unchanged.
struct SidebarTagStyle: Equatable, Sendable {
    /// Fill of the tag; nil for the outline-only "no color" tag.
    let fill: LabelRGB?
    /// Outline drawn over the fill, or (without a fill) alone.
    let outline: LabelRGB?

    static func resolve(_ colors: LabelColors, appearance: LabelPillStyle.Appearance) -> SidebarTagStyle {
        let style = LabelPillStyle.resolve(colors, appearance: appearance, shape: .dot)
        guard colors.isColored else { return SidebarTagStyle(fill: nil, outline: style.border) }
        guard appearance == .dark else {
            return SidebarTagStyle(fill: style.fill, outline: style.needsBorder ? style.border : nil)
        }
        let surface = LabelPillStyle.sidebarSurface(.dark)
        var candidate = style.fill
        for step in 0...100 where candidate.difference(from: surface) < LabelPillStyle.minimumTagDifference {
            let t = Double(step) / 100
            candidate = LabelRGB(r: style.fill.r + (1 - style.fill.r) * t,
                                 g: style.fill.g + (1 - style.fill.g) * t,
                                 b: style.fill.b + (1 - style.fill.b) * t)
        }
        return SidebarTagStyle(fill: candidate, outline: nil)
    }
}
