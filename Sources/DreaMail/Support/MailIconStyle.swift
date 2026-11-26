import SwiftUI

/// Size and weight of the navigation glyphs: main sidebar rows, "Add view"
/// and the Settings sidebar.
///
/// The `.sidebar` list style draws a Label's icon from its own symbol
/// configuration: large and light on macOS 26, which reads soft and rounded
/// next to the row title. These glyphs set an explicit font instead: medium
/// weight, at the row title's size for the macOS "Sidebar icon size"
/// setting (System Settings ▸ Appearance), so the glyph's cap height matches
/// the text.
struct MailIconMetrics: Equatable {
    let pointSize: CGFloat
    /// Width of the icon column, so outline and filled glyphs of different
    /// widths keep the titles aligned.
    let columnWidth: CGFloat
    let weight: Font.Weight

    /// Small, medium and large sidebar rows title their rows at 11, 13 and
    /// 15 pt.
    init(rowSize: SidebarRowSize) {
        if rowSize == .small {
            pointSize = 11
        } else if rowSize == .large {
            pointSize = 15
        } else {
            pointSize = 13
        }
        columnWidth = pointSize + 5
        weight = .medium
    }

    var font: Font { .system(size: pointSize, weight: weight) }
}

private struct MailIconModifier: ViewModifier {
    let selected: Bool
    /// The "Sidebar icon size" setting (macOS 14+, this app's minimum).
    @Environment(\.mailRowSize) private var rowSize
    /// `.increased` inside a row drawn over the emphasized (accent) selection.
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.mailAccent) private var accent

    func body(content: Content) -> some View {
        let metrics = MailIconMetrics(rowSize: rowSize)
        content
            .font(metrics.font)
            .imageScale(.medium)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.mailIcon(selected: selected, prominence: prominence, accent: accent))
            .frame(width: metrics.columnWidth)
    }
}

private struct MailRowSizeOverrideKey: EnvironmentKey {
    static let defaultValue: SidebarRowSize? = nil
}

extension EnvironmentValues {
    /// Set by a Compact sidebar: the row size the user chose, while the list
    /// itself is drawn with the small one. Glyphs and titles keep that size.
    var mailRowSizeOverride: SidebarRowSize? {
        get { self[MailRowSizeOverrideKey.self] }
        set { self[MailRowSizeOverrideKey.self] = newValue }
    }

    /// The row size glyph and title metrics follow.
    var mailRowSize: SidebarRowSize { mailRowSizeOverride ?? sidebarRowSize }
}

private struct SidebarRowSelectedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the sidebar row drawing this is the selected one (the title
    /// takes the selection ink on a painted selection, focused or not).
    var sidebarRowSelected: Bool {
        get { self[SidebarRowSelectedKey.self] }
        set { self[SidebarRowSelectedKey.self] = newValue }
    }
}

private struct MailRowTitleModifier: ViewModifier {
    @Environment(\.sidebarRowSelected) private var selected
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.mailAccent) private var accent
    @Environment(\.mailRowSizeOverride) private var sizeOverride

    func body(content: Content) -> some View {
        // Only in a Compact sidebar: the title keeps the size of the user's
        // row size, whatever the list draws.
        content
            .font(sizeOverride.map { .system(size: MailIconMetrics(rowSize: $0).pointSize) })
            .foregroundStyle(.mailRowTitle(selected: selected, prominence: prominence, accent: accent))
    }
}

extension View {
    /// The one style for sidebar glyphs (see `MailIconMetrics`), in the
    /// monochrome `mailIcon` tint: never the accent, selected or not. On the
    /// solid accent capsule of an emphasized selection it is white (with a
    /// custom accent: white or black, by `AccentPalette.onFill`).
    func mailIconStyle(selected: Bool) -> some View {
        modifier(MailIconModifier(selected: selected))
    }

    /// Title of a navigation sidebar row: the label colour, white (or the
    /// custom accent's `onFill`) on an emphasized selection; never the accent.
    func mailRowTitleStyle() -> some View {
        modifier(MailRowTitleModifier())
    }
}
