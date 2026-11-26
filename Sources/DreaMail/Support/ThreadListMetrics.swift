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

/// The one source of the thread row's vertical measures that depend on the
/// density. Comfortable is today's layout. Section headers do not change.
struct ThreadListMetrics: Equatable {
    let density: ListDensity
    let fontScale: Double

    init(density: ListDensity, fontScale: Double = 1.0) {
        self.density = density
        self.fontScale = fontScale
    }

    /// Padding above and below a thread row's content.
    var rowVerticalPadding: Double { (density == .compact ? 2 : 6) * fontScale }

    /// The row's content: the trailing strip (chips, icons, date).
    var rowContentHeight: Double { ThreadRowChipLayout.trailingStripHeight * fontScale }

    /// Extra hit area of a hover action, above and below. Compact: no more
    /// than the row's padding, so a target never reaches the next row.
    var hitExtraV: Double {
        density == .compact ? min(ThreadRowActionLayout.hitExtraV, rowVerticalPadding)
                            : ThreadRowActionLayout.hitExtraV
    }
}

/// Density of the sidebar, a setting of its own (Settings → Appearance).
/// Comfortable is today's sidebar.
enum SidebarDensity: String, CaseIterable, Identifiable {
    case comfortable, compact

    static let storageKey = "sidebarDensity"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }

    static func from(raw: String) -> SidebarDensity { SidebarDensity(rawValue: raw) ?? .comfortable }

    /// Minimum height of a sidebar row, in points. Icons and fonts keep their size.
    var minRowHeight: Double { self == .compact ? 22 : 30 }

    /// Vertical space taken off each side of a sidebar row's content, in
    /// points: the row's own height (the system's insets around the title)
    /// is what the minimum above never reached. Comfortable takes none.
    var rowVerticalTrim: Double { self == .compact ? 3 : 0 }
}
