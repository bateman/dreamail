import AppKit
import os
import SwiftUI

/// The app's accent colour preference (Settings → Appearance): the default
/// palette, or one colour the user picked. An app preference, not account
/// data: stored in UserDefaults as `#rrggbb`. Missing, empty or malformed
/// means the default, so no arbitrary string ever reaches a colour.
enum AccentPreference {
    static let storageKey = "accentColor"

    /// The custom accent, or nil for the default.
    static func custom(raw: String?) -> LabelRGB? {
        LabelRGB(hexString: LabelRGB.normalizedHex(raw))
    }

    /// The value to store for a pick: `#rrggbb`, or "" (the default) for
    /// nil, empty or malformed input.
    static func storedValue(_ hex: String?) -> String {
        LabelRGB.normalizedHex(hex) ?? ""
    }

    /// One-click choices under the colour well: the label palette's hues
    /// that work as an accent (no grey or brown).
    static let presets: [(name: String, hex: String)] = Color.labelPalette.filter {
        $0.name != "Gray" && $0.name != "Brown"
    }
}

/// The one rule for drawing with the accent, for one appearance.
///
/// - `fill`: the accent itself, unmodified (painted selection, badges,
///   washes, the app's own filled buttons).
/// - `onFill`: text and glyphs drawn on the fill: white when it reaches
///   4.5:1, else black (which then always does: white below 4.5:1 means a
///   luminance above 0.183, where black is at least 4.67:1).
/// - `foreground`: the accent as a glyph or a small indicator (dots, rings,
///   switch tracks) on the app's surfaces: the accent when it reaches 3:1
///   on every one of them, else the same hue and saturation with the
///   lightness moved just far enough (darker in light mode, lighter in dark
///   mode) to reach it.
/// - `text`: the accent as text (links, chip and button captions): the same
///   move, to 4.5:1, also against the accent's own chip wash.
/// - `control`: what system controls are tinted with (`.tint`): they draw
///   their own white label on it (bordered-prominent buttons), so it is the
///   accent darkened, same hue, until white reaches 4.5:1 on it.
/// - `selectionBorder`: the fill is below 1.3:1 against a row or sidebar
///   surface (white on white, black on dark): the painted selection then
///   gets a `foreground` outline so it never vanishes.
///
/// A pick with almost no chroma (below 0.05) moves as a grey: #fefeff must
/// not turn into a vivid periwinkle. The default palette is not run through
/// the rule: it is the app's fixed blue with white on it, exactly as before
/// the setting existed.
struct AccentPalette: Equatable, Sendable {
    typealias Appearance = LabelPillStyle.Appearance

    let fill: LabelRGB
    let onFill: LabelRGB
    let foreground: LabelRGB
    let text: LabelRGB
    let control: LabelRGB
    let selectionBorder: Bool

    static let minimumOnFillContrast = 4.5
    static let minimumForegroundContrast = 3.0
    static let minimumTextContrast = 4.5
    static let minimumSelectionContrast = 1.3
    /// Opacity of the accent chip wash (filter chips) that accent text sits on.
    static let chipWashOpacity = 0.22
    /// Below this chroma (max - min channel) a pick is treated as a grey.
    static let greyChroma = 0.05

    /// The fixed default blue (`NSColor.mailAccent` before the setting).
    static func defaultAccent(_ appearance: Appearance) -> LabelRGB {
        appearance == .light ? LabelRGB(hex: 0x2383E2) : LabelRGB(hex: 0x2E9BE8)
    }

    static func `default`(_ appearance: Appearance) -> AccentPalette {
        let blue = defaultAccent(appearance)
        return AccentPalette(fill: blue, onFill: .white, foreground: blue, text: blue,
                             control: blue, selectionBorder: false)
    }

    /// The app surfaces an accent glyph, text or selection sits on: content
    /// and sidebar backgrounds (`Color.mailContent`, `Color.mailSidebar`)
    /// and the read-row wash.
    static func surfaces(_ appearance: Appearance) -> [LabelRGB] {
        let sidebar = appearance == .light ? LabelRGB(hex: 0xF7F7F5) : LabelRGB(hex: 0x232323)
        return [LabelPillStyle.surfaceColor(.content, appearance),
                LabelPillStyle.surfaceColor(.readRow, appearance),
                sidebar]
    }

    /// Surfaces for accent text: the above plus the accent's chip wash.
    static func textSurfaces(_ accent: LabelRGB, _ appearance: Appearance) -> [LabelRGB] {
        let content = LabelPillStyle.surfaceColor(.content, appearance)
        return surfaces(appearance) + [content.composited(under: accent, alpha: chipWashOpacity)]
    }

    /// The palette for a custom accent (nil: the default palette).
    static func resolve(_ accent: LabelRGB?, appearance: Appearance) -> AccentPalette {
        guard let accent else { return .default(appearance) }
        let darken = appearance == .light
        let rows = surfaces(appearance)
        return AccentPalette(
            fill: accent,
            onFill: onFill(accent),
            foreground: adjusted(accent, on: rows, minimum: minimumForegroundContrast, darken: darken),
            text: adjusted(accent, on: textSurfaces(accent, appearance),
                           minimum: minimumTextContrast, darken: darken),
            control: adjusted(accent, on: [.white], minimum: minimumOnFillContrast, darken: true),
            selectionBorder: rows.contains { accent.contrast(with: $0) < minimumSelectionContrast })
    }

    /// White or black, whichever the rule picks for text on `fill`.
    static func onFill(_ fill: LabelRGB) -> LabelRGB {
        fill.contrast(with: .white) >= minimumOnFillContrast ? .white : .black
    }

    /// `color` with its lightness moved toward black (`darken`) or white
    /// until it reaches `minimum` on every surface; unchanged when it
    /// already does. Near-greys move as greys.
    static func adjusted(_ color: LabelRGB, on surfaces: [LabelRGB], minimum: Double,
                         darken: Bool) -> LabelRGB {
        func worst(_ c: LabelRGB) -> Double { surfaces.map { c.contrast(with: $0) }.min() ?? 21 }
        if worst(color) >= minimum { return color }
        var hsl = HSL(color)
        if max(color.r, color.g, color.b) - min(color.r, color.g, color.b) < greyChroma {
            hsl = HSL(h: 0, s: 0, l: hsl.l)
        }
        // Lightness only ever moves away from the surfaces, so contrast
        // grows monotonically: bisect for the smallest move that reaches it.
        var near = hsl.l, far = darken ? 0.0 : 1.0
        for _ in 0..<24 {
            let mid = (near + far) / 2
            if worst(hsl.with(l: mid).rgb) >= minimum { far = mid } else { near = mid }
        }
        return hsl.with(l: far).rgb
    }

    /// The opacity for selection ink drawn at a reduced `emphasis` (a
    /// secondary line, a date): the requested one when the blend of `onFill`
    /// over the fill still reaches 4.5:1, else full strength.
    func inkOpacity(_ emphasis: Double) -> Double {
        let blended = fill.composited(under: onFill, alpha: emphasis)
        return blended.contrast(with: fill) >= Self.minimumOnFillContrast ? emphasis : 1
    }
}

extension LabelRGB {
    /// `#rrggbb` (lowercase), components rounded to the nearest byte.
    var hexString: String {
        func byte(_ c: Double) -> Int { Int((min(1, max(0, c)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }
}

/// Hue, saturation, lightness (all 0…1) of an sRGB colour.
struct HSL: Equatable {
    let h: Double
    let s: Double
    let l: Double

    init(h: Double, s: Double, l: Double) {
        self.h = h
        self.s = s
        self.l = l
    }

    init(_ c: LabelRGB) {
        let maxC = max(c.r, c.g, c.b), minC = min(c.r, c.g, c.b)
        let l = (maxC + minC) / 2
        let d = maxC - minC
        guard d > 1e-9 else {
            self.init(h: 0, s: 0, l: l)
            return
        }
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: Double
        if maxC == c.r {
            h = (c.g - c.b) / d + (c.g < c.b ? 6 : 0)
        } else if maxC == c.g {
            h = (c.b - c.r) / d + 2
        } else {
            h = (c.r - c.g) / d + 4
        }
        h /= 6
        self.init(h: h, s: s, l: l)
    }

    func with(l: Double) -> HSL { HSL(h: h, s: s, l: min(1, max(0, l))) }

    var rgb: LabelRGB {
        guard s > 0 else { return LabelRGB(r: l, g: l, b: l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return LabelRGB(r: channel(h + 1.0 / 3), g: channel(h), b: channel(h - 1.0 / 3))
    }
}

/// The accent in effect, as the app-wide provider hands it to views
/// (`EnvironmentValues.mailAccent`, set once per window root by
/// `.mailAccentRoot()`). Views never read the preference themselves. The
/// palettes and colours are resolved once, when the value is made.
struct MailAccent: Equatable, Sendable {
    /// The custom accent, or nil for the default palette.
    let custom: LabelRGB?
    let light: AccentPalette
    let dark: AccentPalette

    /// Theme-adaptive colours for each role.
    let fill: Color
    let onFill: Color
    let foreground: Color
    let text: Color
    let control: Color

    init(custom: LabelRGB?) {
        self.custom = custom
        let light = AccentPalette.resolve(custom, appearance: .light)
        let dark = AccentPalette.resolve(custom, appearance: .dark)
        self.light = light
        self.dark = dark
        func color(_ role: KeyPath<AccentPalette, LabelRGB>) -> Color {
            Color(nsColor: Self.adaptive(light[keyPath: role], dark[keyPath: role]))
        }
        fill = color(\.fill)
        onFill = color(\.onFill)
        foreground = color(\.foreground)
        text = color(\.text)
        control = color(\.control)
    }

    static let `default` = MailAccent(custom: nil)

    /// Equal accents resolve to equal palettes.
    static func == (lhs: MailAccent, rhs: MailAccent) -> Bool { lhs.custom == rhs.custom }

    var isCustom: Bool { custom != nil }

    func palette(_ appearance: LabelPillStyle.Appearance) -> AccentPalette {
        appearance == .light ? light : dark
    }

    func palette(scheme: ColorScheme) -> AccentPalette {
        scheme == .dark ? dark : light
    }

    /// Whether the app paints list selections in the accent
    /// (`AccentSelectionBackground`). Only with a custom accent, and only
    /// where the mechanism is verified (macOS 26: a row background drawn
    /// over AppKit's highlight, `backgroundProminence` reporting the
    /// emphasized selection). Elsewhere selections keep the system
    /// highlight and ink; the accent still applies everywhere else.
    var paintsSelection: Bool {
        guard isCustom else { return false }
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Whether a selected row keeps its accent colour (custom, or the
    /// system's emphasized selection colour) when its list is not focused
    /// or the window is inactive, as Gmail's open conversation and current
    /// mailbox do: the colour means "this is open", not "this list has
    /// focus". Same macOS 26 mechanism as `paintsSelection`.
    var keepsSelectionColor: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    func nsColor(_ role: KeyPath<AccentPalette, LabelRGB>) -> NSColor {
        Self.adaptive(light[keyPath: role], dark[keyPath: role])
    }

    private static func adaptive(_ light: LabelRGB, _ dark: LabelRGB) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        }
    }

    /// Places that drew with the system accent before the setting (menu
    /// highlights in sheets, Settings, AppKit text views): still the system
    /// accent by default, the custom accent's matching role once one is
    /// picked. Kept as a family because Default must not change them.
    var fillOrSystem: Color { isCustom ? fill : Color.accentColor }
    var onFillOrSystem: Color { isCustom ? onFill : .white }
    var foregroundOrSystem: Color { isCustom ? foreground : Color.accentColor }
    var textOrSystem: Color { isCustom ? text : Color.accentColor }
    var nsFillOrSystem: NSColor { isCustom ? nsColor(\.fill) : .controlAccentColor }
    var nsTextOrSystem: NSColor { isCustom ? nsColor(\.text) : .controlAccentColor }

    /// For AppKit code with no SwiftUI environment (text views): the accent
    /// last provided by a window root. Such views pick a change up on their
    /// next highlight pass.
    static var current: MailAccent {
        get { currentLock.withLock { $0 } }
        set { currentLock.withLock { $0 = newValue } }
    }

    private static let currentLock = OSAllocatedUnfairLock(initialState: MailAccent.default)
}

private struct MailAccentKey: EnvironmentKey {
    static let defaultValue = MailAccent.default
}

extension EnvironmentValues {
    /// The accent in effect (see `MailAccent`).
    var mailAccent: MailAccent {
        get { self[MailAccentKey.self] }
        set { self[MailAccentKey.self] = newValue }
    }
}

/// The accent as a shape style that resolves from the environment, so a
/// view drawing with it follows the setting without reading it.
struct MailAccentStyle: ShapeStyle {
    enum Role: Sendable { case fill, onFill, foreground, text, fillOrSystem, foregroundOrSystem, textOrSystem }
    let role: Role

    func resolve(in environment: EnvironmentValues) -> Color {
        let accent = environment.mailAccent
        switch role {
        case .fill: return accent.fill
        case .onFill: return accent.onFill
        case .foreground: return accent.foreground
        case .text: return accent.text
        case .fillOrSystem: return accent.fillOrSystem
        case .foregroundOrSystem: return accent.foregroundOrSystem
        case .textOrSystem: return accent.textOrSystem
        }
    }
}

extension ShapeStyle where Self == MailAccentStyle {
    /// The accent as a fill: selection, prominent controls, badges, washes.
    static var accentFill: MailAccentStyle { MailAccentStyle(role: .fill) }
    /// Text or glyphs drawn on `accentFill`.
    static var onAccentFill: MailAccentStyle { MailAccentStyle(role: .onFill) }
    /// The accent as a glyph or small indicator on the app's surfaces (3:1).
    static var accentForeground: MailAccentStyle { MailAccentStyle(role: .foreground) }
    /// The accent as text on the app's surfaces and its chip wash (4.5:1).
    static var accentText: MailAccentStyle { MailAccentStyle(role: .text) }
    /// `accentFill`, or the system accent with the default palette.
    static var accentFillOrSystem: MailAccentStyle { MailAccentStyle(role: .fillOrSystem) }
    /// `accentForeground`, or the system accent with the default palette.
    static var accentForegroundOrSystem: MailAccentStyle { MailAccentStyle(role: .foregroundOrSystem) }
    /// `accentText`, or the system accent with the default palette.
    static var accentTextOrSystem: MailAccentStyle { MailAccentStyle(role: .textOrSystem) }
}

/// Reads the preference once per window root and provides it: the
/// `mailAccent` environment value, and `.tint` for system control fills
/// (bordered-prominent buttons, toggles, pickers, progress) in the palette's
/// `control` role, where their own white labels stay readable. `.tint` is
/// never used as a text or glyph colour: those take `.accentText` or
/// `.accentForeground`.
private struct MailAccentRoot: ViewModifier {
    @AppStorage(AccentPreference.storageKey) private var raw = ""
    /// Whether the default palette tints system controls with the app blue
    /// (main window, as before the setting) or leaves them to the system
    /// (Settings, as before the setting).
    let tintsDefault: Bool

    func body(content: Content) -> some View {
        let accent = MailAccent(custom: AccentPreference.custom(raw: raw))
        content
            .environment(\.mailAccent, accent)
            .tint(accent.isCustom || tintsDefault ? accent.control : nil)
            .onChange(of: accent, initial: true) { _, new in MailAccent.current = new }
    }
}

extension View {
    /// Provide the accent to everything under a window root.
    func mailAccentRoot(tintsDefault: Bool) -> some View {
        modifier(MailAccentRoot(tintsDefault: tintsDefault))
    }
}

// MARK: - Selection highlight

/// A selectable row's `listRowBackground`, painting the selection.
///
/// AppKit draws a `List`'s selection (the sidebar capsule, the thread
/// row) in the system accent while the list is focused in the key window,
/// in grey otherwise, and ignores `.tint`. A row's `listRowBackground` is
/// drawn over that highlight, and it still sees the list's own selection
/// state through `backgroundProminence` (`.increased` while the selection
/// is emphasized). The selected row is painted whatever the focus, like
/// Gmail's open conversation and current mailbox: the colour says "this is
/// open". With a custom accent (`MailAccent.paintsSelection`) the fill is
/// the accent in every state; with the default, the system's emphasized
/// selection colour where AppKit would draw grey (unfocused list, inactive
/// window), and AppKit's own highlight when emphasized.
///
/// Two lists can then show an accent row at once, so the focused one (the
/// emphasized selection) also gets a thin bar in the selection ink at its
/// leading edge, as Gmail marks the focused row.
/// `List(selection:)`, keyboard navigation, VoiceOver and drag and drop
/// are untouched: only the paint changes. A fill that would vanish into
/// the surface (`AccentPalette.selectionBorder`) gets an outline.
struct AccentSelectionBackground: View {
    let selected: Bool
    let accent: MailAccent
    /// 0 for the thread list's full-width row; the sidebar's capsule is
    /// rounded.
    let cornerRadius: CGFloat
    var unselected: Color = .clear
    /// Gap to the row's left and right edges. Only the full sidebar rows
    /// (`sidebar(selected:accent:)`) set it; the thread list's band and the
    /// icon strip's own 32 pt capsule keep their geometry (0).
    var horizontalInset: CGFloat = 0
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.colorScheme) private var colorScheme

    /// Corner radius of the icon strip's capsule (its own geometry).
    static let sidebarCornerRadius: CGFloat = 6
    /// Corner radius of the full sidebar rows' capsule: AppKit's own, from
    /// the same measurement (its corner, 2 pt below the top edge, starts
    /// 2 pt in: a radius of 8 where 6 starts 1 pt in).
    static let sidebarRowCornerRadius: CGFloat = 8
    /// Width of the focus bar at the selected row's leading edge.
    static let focusBarWidth: CGFloat = 3
    /// Gap between the row background's edges and the painted capsule on
    /// each side. A row background spans the whole row, wider than AppKit's
    /// own capsule, and SwiftUI does not expose the system's inset. Measured
    /// by `SidebarSelectionGeometryUITests` on macOS 26.7.2 (CI run
    /// 45892085129): with 10 pt the painted capsule and AppKit's own
    /// (default accent, focused list) both span x 82-285 in the window, at
    /// the same height. The one place to change it.
    static let sidebarHorizontalInset: CGFloat = 10

    /// Sidebar rows (main window and Settings): nil unless the app paints
    /// this row, so the system draws everything else exactly as before.
    static func sidebar(selected: Bool, accent: MailAccent) -> AccentSelectionBackground? {
        accent.paintsSelection || (selected && accent.keepsSelectionColor)
            ? AccentSelectionBackground(selected: selected, accent: accent,
                                        cornerRadius: sidebarRowCornerRadius,
                                        horizontalInset: sidebarHorizontalInset)
            : nil
    }

    var body: some View {
        if selected, accent.keepsSelectionColor {
            let emphasized = prominence == .increased
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            Group {
                if accent.isCustom || !emphasized {
                    shape
                        .fill(accent.isCustom ? accent.fill : Color(nsColor: .selectedContentBackgroundColor))
                        .overlay {
                            if accent.isCustom, accent.palette(scheme: colorScheme).selectionBorder {
                                shape.strokeBorder(accent.foreground, lineWidth: 1)
                            }
                        }
                } else {
                    // Default accent, emphasized: AppKit's own highlight.
                    unselected
                }
            }
            .overlay(alignment: .leading) {
                if emphasized {
                    Rectangle()
                        .fill(accent.isCustom ? accent.onFill : Color.mailOnEmphasizedSelection)
                        .frame(width: Self.focusBarWidth)
                        .padding(.vertical, cornerRadius)
                        .padding(.leading, cornerRadius > 0 ? Self.focusBarWidth : 0)
                }
            }
            .padding(.horizontal, horizontalInset)
            .accessibilityHidden(true)
        } else {
            unselected
        }
    }
}

/// Ink for a selected row's text and glyphs where the app keeps the
/// selection colour (`AccentSelectionBackground`), in every state, focused
/// or not, so the row looks the same whatever has the focus: the rule's
/// `onFill` (white or black) on a custom accent, the emphasized selection
/// ink (white) on the default one. Nil elsewhere, and the row draws its
/// usual colours. Callers pass whether the row is the selected one; the
/// prominence is not needed any more.
enum SelectionInk {
    static func color(selected: Bool, prominence: BackgroundProminence,
                      accent: MailAccent) -> Color? {
        guard selected, accent.keepsSelectionColor else { return nil }
        return accent.isCustom ? accent.onFill : Color.mailOnEmphasizedSelection
    }
}

/// A sidebar count on a selected row: the selection ink on the capsule (white
/// on the system's emphasized highlight), the secondary label colour elsewhere.
struct SidebarBadgeStyle: ShapeStyle {
    let selected: Bool

    /// The selection ink for a selected row (white on the system's
    /// emphasized highlight too); nil on any other row.
    static func ink(selected: Bool, prominence: BackgroundProminence, accent: MailAccent) -> Color? {
        SelectionInk.color(selected: selected, prominence: prominence, accent: accent)
            ?? (selected && prominence == .increased ? Color.mailOnEmphasizedSelection : nil)
    }

    func resolve(in environment: EnvironmentValues) -> Color {
        Self.ink(selected: selected, prominence: environment.backgroundProminence,
                 accent: environment.mailAccent)
            ?? Color(nsColor: .secondaryLabelColor)
    }
}
