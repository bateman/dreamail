import Foundation

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
