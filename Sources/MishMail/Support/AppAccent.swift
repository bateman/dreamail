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

    static func read(_ defaults: UserDefaults = .standard) -> LabelRGB? {
        custom(raw: defaults.string(forKey: storageKey))
    }

    static func write(_ hex: String?, to defaults: UserDefaults = .standard) {
        let value = storedValue(hex)
        if value.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(value, forKey: storageKey)
        }
    }

    static func reset(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    /// One-click choices under the colour well: the label palette's hues
    /// that work as an accent (no grey or brown).
    static let presets: [(name: String, hex: String)] = Color.labelPalette.filter {
        $0.name != "Gray" && $0.name != "Brown"
    }
}

/// The one rule for drawing with the accent, for one appearance.
///
/// - `fill`: the accent itself, unmodified (selection highlights,
///   prominent buttons, badges, washes).
/// - `onFill`: text and glyphs drawn on the fill: white when it reaches
///   4.5:1, else black (which then always does: white below 4.5:1 means a
///   luminance above 0.183, where black is at least 4.67:1).
/// - `foreground`: the accent as a glyph or text colour on the app's own
///   surfaces (content, sidebar, read-row wash): the accent when it reaches
///   3:1 on every one of them, else the same hue and saturation with the
///   lightness moved just far enough (darker in light mode, lighter in dark
///   mode) to reach it.
///
/// The default palette is not run through the rule: it is the app's fixed
/// blue with white on it, exactly as before the setting existed.
struct AccentPalette: Equatable, Sendable {
    typealias Appearance = LabelPillStyle.Appearance

    let fill: LabelRGB
    let onFill: LabelRGB
    let foreground: LabelRGB

    static let minimumOnFillContrast = 4.5
    static let minimumForegroundContrast = 3.0

    /// The fixed default blue (`NSColor.mailAccent` before the setting).
    static func defaultAccent(_ appearance: Appearance) -> LabelRGB {
        appearance == .light ? LabelRGB(hex: 0x2383E2) : LabelRGB(hex: 0x2E9BE8)
    }

    static func `default`(_ appearance: Appearance) -> AccentPalette {
        let blue = defaultAccent(appearance)
        return AccentPalette(fill: blue, onFill: .white, foreground: blue)
    }

    /// The app surfaces an accent glyph or text sits on: content and
    /// sidebar backgrounds (`Color.mailContent`, `Color.mailSidebar`) and
    /// the read-row wash.
    static func surfaces(_ appearance: Appearance) -> [LabelRGB] {
        let sidebar = appearance == .light ? LabelRGB(hex: 0xF7F7F5) : LabelRGB(hex: 0x232323)
        return [LabelPillStyle.surfaceColor(.content, appearance),
                LabelPillStyle.surfaceColor(.readRow, appearance),
                sidebar]
    }

    /// The palette for a custom accent (nil: the default palette).
    static func resolve(_ accent: LabelRGB?, appearance: Appearance) -> AccentPalette {
        guard let accent else { return .default(appearance) }
        return AccentPalette(fill: accent,
                             onFill: onFill(accent),
                             foreground: foreground(accent, on: surfaces(appearance),
                                                    darken: appearance == .light))
    }

    /// White or black, whichever the rule picks for text on `fill`.
    static func onFill(_ fill: LabelRGB) -> LabelRGB {
        fill.contrast(with: .white) >= minimumOnFillContrast ? .white : .black
    }

    /// `accent` with its lightness moved toward black (`darken`) or white
    /// until it reaches 3:1 on every surface; unchanged when it already does.
    static func foreground(_ accent: LabelRGB, on surfaces: [LabelRGB], darken: Bool) -> LabelRGB {
        func worst(_ c: LabelRGB) -> Double { surfaces.map { c.contrast(with: $0) }.min() ?? 21 }
        if worst(accent) >= minimumForegroundContrast { return accent }
        let hsl = HSL(accent)
        // Lightness only ever moves away from the surfaces, so contrast
        // grows monotonically: bisect for the smallest move that reaches it.
        var near = hsl.l, far = darken ? 0.0 : 1.0
        for _ in 0..<24 {
            let mid = (near + far) / 2
            if worst(hsl.with(l: mid).rgb) >= minimumForegroundContrast { far = mid } else { near = mid }
        }
        return hsl.with(l: far).rgb
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
/// `.mailAccentRoot()`). Views never read the preference themselves.
struct MailAccent: Equatable, Sendable {
    /// The custom accent, or nil for the default palette.
    let custom: LabelRGB?

    static let `default` = MailAccent(custom: nil)

    var isCustom: Bool { custom != nil }

    func palette(_ appearance: LabelPillStyle.Appearance) -> AccentPalette {
        AccentPalette.resolve(custom, appearance: appearance)
    }

    /// Theme-adaptive colours for each role.
    var fill: Color { color(\.fill) }
    var onFill: Color { color(\.onFill) }
    var foreground: Color { color(\.foreground) }

    var nsFill: NSColor { nsColor(\.fill) }
    var nsForeground: NSColor { nsColor(\.foreground) }

    private func color(_ role: KeyPath<AccentPalette, LabelRGB>) -> Color {
        Color(nsColor: nsColor(role))
    }

    func nsColor(_ role: KeyPath<AccentPalette, LabelRGB>) -> NSColor {
        let light = palette(.light)[keyPath: role], dark = palette(.dark)[keyPath: role]
        return NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        }
    }

    /// Places that drew with the system accent before the setting (menu
    /// highlights in sheets, Settings, AppKit text views): still the system
    /// accent by default, the custom accent once one is picked.
    var fillOrSystem: Color { isCustom ? fill : Color.accentColor }
    var onFillOrSystem: Color { isCustom ? onFill : .white }
    var foregroundOrSystem: Color { isCustom ? foreground : Color.accentColor }
    var nsFillOrSystem: NSColor { isCustom ? nsFill : .controlAccentColor }
    var nsForegroundOrSystem: NSColor { isCustom ? nsForeground : .controlAccentColor }

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
    enum Role: Sendable { case fill, onFill, foreground, fillOrSystem, foregroundOrSystem }
    let role: Role

    func resolve(in environment: EnvironmentValues) -> Color {
        let accent = environment.mailAccent
        switch role {
        case .fill: return accent.fill
        case .onFill: return accent.onFill
        case .foreground: return accent.foreground
        case .fillOrSystem: return accent.fillOrSystem
        case .foregroundOrSystem: return accent.foregroundOrSystem
        }
    }
}

extension ShapeStyle where Self == MailAccentStyle {
    /// The accent as a fill: selection, prominent controls, badges, washes.
    static var accentFill: MailAccentStyle { MailAccentStyle(role: .fill) }
    /// Text or glyphs drawn on `accentFill`.
    static var onAccentFill: MailAccentStyle { MailAccentStyle(role: .onFill) }
    /// The accent as a text or glyph colour on the app's surfaces.
    static var accentForeground: MailAccentStyle { MailAccentStyle(role: .foreground) }
    /// `accentFill`, or the system accent with the default palette.
    static var accentFillOrSystem: MailAccentStyle { MailAccentStyle(role: .fillOrSystem) }
    /// `accentForeground`, or the system accent with the default palette.
    static var accentForegroundOrSystem: MailAccentStyle { MailAccentStyle(role: .foregroundOrSystem) }
}

/// Reads the preference once per window root and provides it: the
/// `mailAccent` environment value, and `.tint` for system controls
/// (bordered-prominent buttons, toggles, pickers, links, progress).
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
            .tint(accent.isCustom || tintsDefault ? accent.fill : nil)
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

/// Who draws a selected list row's highlight.
///
/// AppKit draws a `List`'s selection (the sidebar capsule, the thread
/// row) in the system accent and ignores `.tint`. A row's
/// `listRowBackground` is drawn over that highlight, and it still sees the
/// list's own selection state through `backgroundProminence` (`.increased`
/// while the selection is emphasized: focused list in the key window). So
/// with a custom accent the app paints the emphasized highlight itself and
/// leaves every other state (unfocused list, inactive window: the grey
/// highlight) to AppKit. `List(selection:)`, keyboard navigation, VoiceOver
/// and drag and drop are untouched: only the paint changes.
enum SelectionHighlight: Equatable, Sendable {
    /// The app paints the custom accent over the system highlight.
    case accent
    /// The system highlight shows (default accent, or not emphasized).
    case system

    static func resolve(accent: MailAccent, emphasized: Bool) -> SelectionHighlight {
        accent.isCustom && emphasized ? .accent : .system
    }
}

/// A selectable row's `listRowBackground`: the custom accent while the
/// row's selection is emphasized, `unselected` otherwise.
struct AccentSelectionBackground: View {
    let selected: Bool
    let accent: MailAccent
    /// 0 for the thread list's full-width row; the sidebar's capsule is
    /// rounded.
    let cornerRadius: CGFloat
    var unselected: Color = .clear
    @Environment(\.backgroundProminence) private var prominence

    /// Corner radius of the sidebar capsule this paints over.
    static let sidebarCornerRadius: CGFloat = 6

    /// Sidebar rows (main window and Settings): nil with the default
    /// accent, so the system draws everything exactly as before.
    static func sidebar(selected: Bool, accent: MailAccent) -> AccentSelectionBackground? {
        accent.isCustom
            ? AccentSelectionBackground(selected: selected, accent: accent,
                                        cornerRadius: sidebarCornerRadius)
            : nil
    }

    var body: some View {
        if selected,
           SelectionHighlight.resolve(accent: accent, emphasized: prominence == .increased) == .accent {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(accent.fill)
                .accessibilityHidden(true)
        } else {
            unselected
        }
    }
}

/// Ink for a row's text and glyphs: on an emphasized selection in a
/// custom accent, the rule's `onFill` (white or black); otherwise nil, and
/// the row draws its usual colours (AppKit turns them white on its own
/// highlight).
struct SelectionInk {
    static func color(selected: Bool, prominence: BackgroundProminence,
                      accent: MailAccent) -> Color? {
        guard selected, prominence == .increased, accent.isCustom else { return nil }
        return accent.onFill
    }
}

/// A sidebar count with a custom accent: the selection ink on the painted
/// capsule, the secondary label colour elsewhere.
struct SidebarBadgeStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        SelectionInk.color(selected: true, prominence: environment.backgroundProminence,
                           accent: environment.mailAccent)
            ?? Color(nsColor: .secondaryLabelColor)
    }
}
