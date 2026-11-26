import Foundation
import CoreGraphics

/// The colors of the account rail, in one place (the SwiftUI colors are
/// in `AccountRail.swift`). Fixed colors of their own, not the accent: the
/// account rings are colored and the unread badge is red, so an
/// accent-tinted strip would fight with them. Both backgrounds are a step
/// darker than the sidebar (`Color.mailSidebar`: F7F7F5 / 232323) so the rail
/// reads as a separate strip; the dark one is a slate.
enum AccountRailPalette {
    static let backgroundLight: UInt32 = 0xE4E5E8
    static let backgroundDark: UInt32 = 0x1A1D23
    /// Gear and other rail glyphs, and the selection ring of "All accounts".
    static let glyphLight: UInt32 = 0x3C4049
    static let glyphDark: UInt32 = 0xD3D6DC
    /// The thin ring around "All accounts" while it is not selected: a grey
    /// that stays visible on the rail in both appearances (light: darker than
    /// the rail; dark: lighter than it).
    static let idleRingLight: UInt32 = 0x9499A3
    static let idleRingDark: UInt32 = 0x6B717C
}

/// Pure measures of the account rail (the view is in `AccountRail.swift`).
enum AccountRailMetrics {
    /// Right edge of the zoom (green) window button, measured from the
    /// window's left edge. Measured on macOS 26 in CI (the UI test reports
    /// the frame): 80 pt; it was ~61 pt before macOS 26. The rail must cover
    /// the three buttons entirely (the top band covers them).
    static let windowButtonsExtent: CGFloat = 80
    /// Visible margin right of the window buttons.
    static let windowButtonsMargin: CGFloat = 10
    /// Avatar diameter and the rail's padding on each side of it.
    static let avatarSize: CGFloat = 40
    static let horizontalPadding: CGFloat = 12
    /// Rail width (64 pt): just wide enough for the avatars. Everything that
    /// depends on the rail's width reads this constant.
    static let width: CGFloat = avatarSize + 2 * horizontalPadding
    /// The top band must reach at least this far from the window's left edge,
    /// so it covers the three window buttons even when the sidebar is hidden.
    static let bandMinimumWidth: CGFloat = windowButtonsExtent + windowButtonsMargin
    /// Width of the collapsed sidebar (`SidebarIconStrip`), right of the
    /// rail: the sidebar glyph (`mailIconStyle`: 11, 13 or 15 pt by the
    /// "Sidebar icon size" setting) in a `stripItemWidth` × `stripItemHeight`
    /// selection band (`stripWidth` wide), with `stripItemInset` on each side. Gmail's
    /// collapsed navigation, icons only.
    static let stripItemWidth: CGFloat = 32
    static let stripItemHeight: CGFloat = 28
    static let stripItemInset: CGFloat = 4
    static let stripWidth: CGFloat = stripItemWidth + 2 * stripItemInset
    /// The band over rail and strip: the strip fills exactly the band's step
    /// past the rail, so their right edges line up. At least
    /// `bandMinimumWidth`, so it still covers the window buttons.
    static let stripBandWidth: CGFloat = max(bandMinimumWidth, width + stripWidth)
    /// Band width: from the window's left edge to the sidebar's right edge
    /// (window coordinates) while the sidebar is on screen; to the strip's
    /// right edge while the collapsed sidebar is; otherwise just
    /// `bandMinimumWidth` (full-window conversation, split compose).
    static func bandWidth(sidebarTrailing: CGFloat, sidebarVisible: Bool,
                          stripVisible: Bool = false) -> CGFloat {
        guard sidebarVisible else { return stripVisible ? stripBandWidth : bandMinimumWidth }
        return max(bandMinimumWidth, sidebarTrailing)
    }
    /// Settings → Appearance: show the "+" (add account) entry. App-wide.
    static let showAddAccountKey = "showAddAccountInRail"
    static let showAddAccountDefault = true
}
