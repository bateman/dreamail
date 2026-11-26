import Foundation

/// The buttons a thread-list row shows on the right while the pointer is on
/// it, after Gmail: archive, trash, mark unread/read, snooze, in this order.
/// Everything else stays in the context menu, the keyboard and the toolbar.
/// The raw value doubles as the UI-test identifier.
enum ThreadRowHoverAction: String, CaseIterable {
    case archive, trash, toggleRead, snooze

    /// SF Symbol (monochrome, macOS 11+). Gmail's archive glyph has a down
    /// arrow; SF Symbols has no such box, so `archivebox` stands in. Only the
    /// read/unread button changes with the thread's state.
    func symbol(isUnread: Bool) -> String {
        switch self {
        case .archive: return "archivebox"
        case .trash: return "trash"
        case .toggleRead: return isUnread ? "envelope.open" : "envelope.badge"
        case .snooze: return "clock"
        }
    }

    /// Tooltip and VoiceOver label. "Trash" as everywhere else in the app.
    func title(isUnread: Bool) -> String {
        switch self {
        case .archive: return "Archive"
        case .trash: return "Trash"
        case .toggleRead: return isUnread ? "Mark as read" : "Mark as unread"
        case .snooze: return "Snooze"
        }
    }
}

/// Width of the row's right-hand slot, where the date and the hover buttons
/// take turns. Both are always laid out (only their opacity changes), so the
/// row never changes size and the text never jumps when the pointer enters.
/// The slot is at least as wide as the buttons; the date (fixed size, with
/// `actionsWidth` as its minimum) widens it when it needs more, so it is never
/// clipped, however long the date is or large the text.
enum ThreadRowActionLayout {
    static let iconSize = 13.0
    /// Horizontal padding is tight (75.5 pt strip); the vertical one keeps the
    /// row height the spacing UI tests were written against.
    static let iconPaddingH = 2.0
    static let iconPaddingV = 3.0
    static let spacing = 2.5
    /// Extra hit area above and below each button (a 34 pt tall target in a
    /// dense row). It also sets the row's accessibility frame, which the
    /// section-spacing UI tests measure: the old buttons used 6 pt.
    static let hitExtraV = 6.0

    /// Width of the four buttons at the list's font scale
    /// (75.5 pt at scale 1: four 17 pt buttons and three 2.5 pt gaps).
    static func actionsWidth(fontScale: Double) -> Double {
        let count = Double(ThreadRowHoverAction.allCases.count)
        let button = iconSize * fontScale + iconPaddingH * 2
        return button * count + spacing * (count - 1)
    }
}
