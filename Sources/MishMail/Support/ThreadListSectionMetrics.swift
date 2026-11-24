import CoreGraphics

/// Vertical rhythm of the thread list's section breaks ("Priority",
/// "Today", "Last 7 days", label groups). Pure numbers so the bounds are
/// unit-testable; every value scales with the list's font scale.
///
/// A break is one header band: a small gap after the previous section's
/// last row, then the title line. There is no section footer: a footer is
/// its own table row on macOS, with a minimum height and no row background,
/// so it showed as an empty white row-sized hole between the grey rows.
enum ThreadListSectionMetrics {
    /// Content height of one thread row: the 18 pt icon line plus 6 pt
    /// vertical padding on each side (mirrors `ThreadRow`). The List adds
    /// its own row insets on top.
    static func rowContentHeight(fontScale: CGFloat) -> CGFloat {
        (18 + 2 * 6) * fontScale
    }

    /// Air between the last row of a section and the next header's title.
    static func sectionGap(fontScale: CGFloat) -> CGFloat {
        6 * fontScale
    }

    /// Height of the header's title line (12 pt semibold text, or the
    /// label pill in the Labels view, which adds 2 pt above and below).
    static func headerTitleHeight(fontScale: CGFloat) -> CGFloat {
        16 * fontScale
    }

    /// Padding the plain List puts above and below a section header's
    /// content, independent of font scale (measured on macOS 26 in the UI
    /// test: a 24 pt header took a 32 pt band). The header takes it back
    /// with negative padding so the band is `headerHeight` alone.
    static let systemHeaderVerticalInset: CGFloat = 4

    /// Whole header band: gap above plus title line.
    static func headerHeight(fontScale: CGFloat) -> CGFloat {
        sectionGap(fontScale: fontScale) + headerTitleHeight(fontScale: fontScale)
    }
}
