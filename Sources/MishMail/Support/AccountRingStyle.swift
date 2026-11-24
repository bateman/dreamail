import Foundation

/// The colored ring around an account's avatar: the account's label color
/// (the one chosen in "Edit Account Labels…", or the default that follows
/// the avatar's hue), drawn as a thin ring with a gap of the background
/// between it and the photo or initial disc, like a presence ring. A thin
/// neutral outer hairline is added when the color is too close to the
/// surface behind it; the color itself is never changed.
struct AccountRingStyle: Equatable, Sendable {
    enum Appearance: Sendable, CaseIterable { case light, dark }

    /// What the avatar sits on.
    enum Surface: Sendable, CaseIterable {
        /// The sidebar background (`Color.mailSidebar`): the switcher header.
        case sidebar
        /// The account switcher popover.
        case popover
        /// A grouped form: Settings → Accounts and "Edit Account Labels…".
        case groupedForm
    }

    /// The ring color as sRGB (the stored color, or the default palette's
    /// stand-in for the avatar hue). Used for the hairline decision; the
    /// view strokes a default ring with the avatar's own system color.
    let color: LabelRGB
    let needsHairline: Bool
    /// Hairline color; only drawn when `needsHairline`.
    let hairline: LabelRGB

    /// Below this ring-to-surface contrast the ring gets a hairline.
    static let minimumRingContrast = 1.5

    /// Every color the surface can take, approximated as opaque sRGB.
    /// Popovers and grouped forms draw a lighter or darker panel depending
    /// on the window state and material, so both ends are listed.
    static func surfaceColors(_ surface: Surface,
                              _ appearance: Appearance) -> [LabelRGB] {
        switch (surface, appearance) {
        case (.sidebar, .light): return [LabelRGB(hex: 0xF7F7F5)]
        case (.sidebar, .dark): return [LabelRGB(hex: 0x232323)]
        case (.popover, .light): return [LabelRGB(hex: 0xFFFFFF), LabelRGB(hex: 0xECECEC)]
        case (.popover, .dark): return [LabelRGB(hex: 0x191919), LabelRGB(hex: 0x2C2C2C)]
        case (.groupedForm, .light): return [LabelRGB(hex: 0xFFFFFF), LabelRGB(hex: 0xF2F2F2)]
        case (.groupedForm, .dark): return [LabelRGB(hex: 0x1E1E1E), LabelRGB(hex: 0x2A2A2A)]
        }
    }

    /// The ring for an account's stored label color (nil or malformed =
    /// the default) on a surface. Below 1.5:1 against any color of the
    /// surface, a neutral hairline that reaches 3:1 against all of them.
    static func resolve(storedHex: String?, accountId: String,
                        appearance: Appearance,
                        surface: Surface) -> AccountRingStyle {
        let color = AccountLabelColor.resolvedRGB(stored: storedHex, accountId: accountId)
        let behind = surfaceColors(surface, appearance)
        let needsHairline = behind.contains { color.contrast(with: $0) < minimumRingContrast }
        return AccountRingStyle(color: color, needsHairline: needsHairline,
                                hairline: hairlineColor(on: behind))
    }

    /// Mid grey where it reaches 3:1 against every surface color, else
    /// black or white, whichever has the larger worst-case contrast.
    static func hairlineColor(on surfaces: [LabelRGB]) -> LabelRGB {
        func worst(_ c: LabelRGB) -> Double { surfaces.map { c.contrast(with: $0) }.min() ?? 21 }
        let grey = LabelRGB(hex: 0x808080)
        if worst(grey) >= 3 { return grey }
        return worst(.white) >= worst(.black) ? .white : .black
    }
}

/// Ring geometry for an avatar of a given size: a 3 pt ring and a 1 pt
/// gap at every size (whole pixels at 2x), drawn inside the avatar's
/// frame. Callers size the frame so the photo keeps its former size
/// (35 pt frame → 27 pt photo, 29 pt → 21 pt).
struct AccountRingMetrics: Equatable, Sendable {
    static let ringWidth = 3.0
    static let gap = 1.0
    /// Outer hairline width, inside the ring's outer edge.
    static let hairlineWidth = 0.5

    /// The avatar's outer frame (unchanged by the ring).
    let size: Double

    /// Diameter of the photo or initial disc inside the gap.
    var photoDiameter: Double { size - 2 * (Self.ringWidth + Self.gap) }
}
