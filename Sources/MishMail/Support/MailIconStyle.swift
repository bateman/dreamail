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
    @Environment(\.sidebarRowSize) private var rowSize
    /// `.increased` inside a row drawn over the emphasized (accent) selection.
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        let metrics = MailIconMetrics(rowSize: rowSize)
        content
            .font(metrics.font)
            .imageScale(.medium)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.mailIcon(selected: selected, prominence: prominence))
            .frame(width: metrics.columnWidth)
    }
}

private struct MailRowTitleModifier: ViewModifier {
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        content.foregroundStyle(.mailRowTitle(prominence: prominence))
    }
}

extension View {
    /// The one style for sidebar glyphs (see `MailIconMetrics`), in the
    /// monochrome `mailIcon` tint: never the accent, selected or not. On the
    /// solid accent capsule of an emphasized selection it is white.
    func mailIconStyle(selected: Bool) -> some View {
        modifier(MailIconModifier(selected: selected))
    }

    /// Title of a navigation sidebar row: the label colour, white on an
    /// emphasized selection (never the accent).
    func mailRowTitleStyle() -> some View {
        modifier(MailRowTitleModifier())
    }
}
