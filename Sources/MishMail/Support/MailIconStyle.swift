import SwiftUI

/// Size, weight and design of the navigation glyphs: main sidebar rows,
/// "Add view", the Settings sidebar and the list-column header.
///
/// The `.sidebar` list style draws a Label's icon from its own symbol
/// configuration: large and light on macOS 26, which reads soft and rounded
/// next to the 13 pt row title. These glyphs set an explicit font instead:
/// the default (not rounded) design, medium weight, and a point size equal
/// to the sidebar row title, so the glyph's cap height matches the text.
struct MailIconMetrics: Equatable {
    /// Point size at font scale 1: the sidebar row title's size.
    static let basePointSize: CGFloat = 13
    /// Width of the icon column at font scale 1, so outline and filled glyphs
    /// of different widths keep the titles aligned.
    static let baseColumnWidth: CGFloat = 18

    let pointSize: CGFloat
    let columnWidth: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(scale: CGFloat = 1) {
        pointSize = Self.basePointSize * scale
        columnWidth = Self.baseColumnWidth * scale
        weight = .medium
        design = .default
    }

    var font: Font { .system(size: pointSize, weight: weight, design: design) }
}

private struct MailIconModifier: ViewModifier {
    let selected: Bool
    let metrics: MailIconMetrics

    func body(content: Content) -> some View {
        content
            .font(metrics.font)
            // Overrides a rounded design inherited from any ancestor.
            .fontDesign(metrics.design)
            .imageScale(.medium)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.mailIcon(selected: selected))
            .frame(width: metrics.columnWidth)
    }
}

extension View {
    /// The one style for navigation glyphs (see `MailIconMetrics`), in the
    /// monochrome `mailIcon` tint: never the accent, selected or not.
    func mailIconStyle(selected: Bool, scale: CGFloat = 1) -> some View {
        modifier(MailIconModifier(selected: selected, metrics: MailIconMetrics(scale: scale)))
    }
}
