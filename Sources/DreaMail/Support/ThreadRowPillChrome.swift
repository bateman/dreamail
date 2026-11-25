import Foundation

/// Chrome for the AI-category pill in a thread list row. User label pills
/// use `LabelPillStyle` (solid Gmail color, contrast-checked text) instead.
///
/// Idle rows use a soft tinted capsule. Selected rows sit on the list
/// highlight, where a 16% tint wash disappears — so focus flips to a
/// stronger tint fill (with white text, set by the row).
enum ThreadRowPillChrome: Equatable, Sendable {
    /// Colored text + low-opacity tint fill (unselected rows).
    case softTint
    /// High-contrast text + stronger tint fill (selected / focused rows).
    case onSelection

    static func forFocused(_ isFocused: Bool) -> ThreadRowPillChrome {
        isFocused ? .onSelection : .softTint
    }

    /// Opacity of the capsule fill (applied over the label tint color).
    var fillOpacity: Double {
        switch self {
        case .softTint: return 0.16
        case .onSelection: return 0.78
        }
    }
}
