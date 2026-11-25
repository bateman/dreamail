import Foundation

/// The buttons a thread-list row shows on the right while the pointer is on
/// it, after Gmail: archive, trash, mark unread/read, snooze, in this order.
/// Everything else stays in the context menu, the keyboard and the toolbar.
enum ThreadRowHoverAction: CaseIterable, Equatable {
    case archive, trash, toggleRead, snooze

    /// The buttons for a row, left to right. The third one flips with the
    /// thread's read state.
    static func actions(isUnread: Bool) -> [Self] { allCases }

    /// SF Symbol (monochrome, macOS 11+). Gmail's archive glyph has a down
    /// arrow; SF Symbols has no such box, so `archivebox` stands in.
    func symbol(isUnread: Bool) -> String {
        switch self {
        case .archive: return "archivebox"
        case .trash: return "trash"
        case .toggleRead: return isUnread ? "envelope.open" : "envelope.badge"
        case .snooze: return "clock"
        }
    }

    /// Tooltip and VoiceOver label.
    func title(isUnread: Bool) -> String {
        switch self {
        case .archive: return "Archive"
        case .trash: return "Trash"
        case .toggleRead: return isUnread ? "Mark as read" : "Mark as unread"
        case .snooze: return "Snooze"
        }
    }

    /// Stable id for UI tests.
    var identifier: String {
        switch self {
        case .archive: return "archive"
        case .trash: return "trash"
        case .toggleRead: return "toggleRead"
        case .snooze: return "snooze"
        }
    }
}

/// Width of the row's right-hand slot, where the date and the hover buttons
/// take turns. Both share one fixed width, so the row never changes size and
/// the text never jumps when the pointer enters.
enum ThreadRowActionLayout {
    static let iconSize = 13.0
    static let iconPadding = 3.0
    static let spacing = 2.0
    /// Narrowest the date column gets.
    static let dateMinWidth = 52.0

    /// Width of the four buttons at the list's font scale.
    static func actionsWidth(fontScale: Double, count: Int = ThreadRowHoverAction.allCases.count) -> Double {
        let button = iconSize * fontScale + iconPadding * 2
        return button * Double(count) + spacing * Double(max(count - 1, 0))
    }

    /// The slot holds the wider of the date and the buttons.
    static func slotWidth(fontScale: Double) -> Double {
        max(dateMinWidth, actionsWidth(fontScale: fontScale))
    }
}
