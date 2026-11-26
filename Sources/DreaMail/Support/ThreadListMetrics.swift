import Foundation

/// Gmail's "Density" setting for the thread list: Comfortable (the default)
/// or Compact. App-wide, stored in UserDefaults.
enum ListDensity: String, CaseIterable, Identifiable {
    case comfortable, compact

    static let storageKey = "listDensity"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }

    /// A stored value that is not a density (old or edited defaults) is Comfortable.
    static func from(raw: String) -> ListDensity { ListDensity(rawValue: raw) ?? .comfortable }
}

/// The one source of every vertical measure that depends on the density:
/// the thread row, the section header gap. Comfortable is today's layout.
struct ThreadListMetrics: Equatable {
    let density: ListDensity
    let fontScale: Double

    init(density: ListDensity, fontScale: Double = 1.0) {
        self.density = density
        self.fontScale = fontScale
    }

    /// Padding above and below a thread row's content, at font scale 1.
    var rowVerticalPaddingBase: Double { density == .compact ? 2 : 6 }
    var rowVerticalPadding: Double { rowVerticalPaddingBase * fontScale }

    /// The row's content: the trailing strip (chips, icons, date).
    var rowContentHeight: Double { ThreadRowChipLayout.trailingStripHeight * fontScale }
    var rowHeight: Double { rowContentHeight + 2 * rowVerticalPadding }

    /// Air between a section's last row and the next header's title,
    /// at font scale 1 (comfortable 6 pt, compact 4 pt: the ratio of the rows).
    var sectionGapBase: Double { density == .compact ? 4 : 6 }
    var sectionGap: Double { sectionGapBase * fontScale }

    /// What the plain List adds above a header's content (macOS 26).
    static let systemHeaderTopInset = 4.0

    /// Top padding of a section header's content: the gap minus the
    /// system inset, never negative (a smaller system inset only widens it).
    var sectionHeaderTopPadding: Double { max(0, sectionGap - Self.systemHeaderTopInset) }
}
