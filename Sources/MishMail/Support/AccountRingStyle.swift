import Foundation

/// The colored ring around an account's avatar: the account's label color
/// (the one chosen in "Edit Account Labels…", or the default that follows
/// the avatar's hue), drawn as a thin ring with a gap of the background
/// between it and the photo or initial disc, like a presence ring. A thin
/// neutral outer hairline is added when the color is too close to the
/// surface behind it; the color itself is never changed.
struct AccountRingStyle: Equatable, Sendable {
    /// What the avatar sits on.
    enum Surface: Sendable, CaseIterable {
        /// The sidebar background (`Color.mailSidebar`): the switcher header.
        case sidebar
        /// The account switcher popover.
        case popover
        /// A grouped form: Settings → Accounts and "Edit Account Labels…".
        case groupedForm
    }

    let color: LabelRGB
    let needsHairline: Bool
    /// Hairline color; only drawn when `needsHairline`.
    let hairline: LabelRGB

    /// Every color the surface can take, approximated as opaque sRGB.
    /// Popovers and grouped forms draw a lighter or darker panel depending
    /// on the window state and material, so both ends are listed.
    static func surfaceColors(_ surface: Surface,
                              _ appearance: LabelPillStyle.Appearance) -> [LabelRGB] {
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
    /// the default) on a surface. The hairline follows the label pill's
    /// rule: below 1.5:1 against any color of the surface, a neutral
    /// outline that reaches 3:1 against all of them.
    static func resolve(storedHex: String?, accountId: String,
                        appearance: LabelPillStyle.Appearance,
                        surface: Surface) -> AccountRingStyle {
        let hex = AccountLabelColor.resolvedHex(stored: storedHex, accountId: accountId)
        let color = LabelRGB(hexString: hex) ?? LabelPillStyle.neutralFill(appearance)
        let behind = surfaceColors(surface, appearance)
        let needsHairline = behind.contains {
            color.contrast(with: $0) < LabelPillStyle.minimumEdgeContrast
        }
        return AccountRingStyle(color: color, needsHairline: needsHairline,
                                hairline: LabelPillStyle.borderColor(on: behind))
    }
}

/// Ring geometry for an avatar of a given size. The ring is drawn inside
/// the avatar's frame, so rows keep their height and text alignment: the
/// photo shrinks by the ring and the gap on each side. 2 pt ring and
/// 1.5 pt gap at 28 pt, scaled with the size and rounded to quarter points.
struct AccountRingMetrics: Equatable, Sendable {
    /// The avatar's outer frame (unchanged by the ring).
    let size: Double
    let ringWidth: Double
    let gap: Double
    /// Outer hairline width, inside the ring's outer edge.
    let hairlineWidth: Double

    /// Diameter of the photo or initial disc inside the gap.
    var photoDiameter: Double { size - 2 * (ringWidth + gap) }

    init(size: Double) {
        func quarter(_ x: Double) -> Double { (x * 4).rounded() / 4 }
        self.size = size
        ringWidth = max(1, quarter(size * 2 / 28))
        gap = max(1, quarter(size * 1.5 / 28))
        hairlineWidth = 0.5
    }
}
