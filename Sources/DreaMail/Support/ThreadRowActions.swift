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
    /// `movesToInbox`: the archive slot shows Gmail's "Move to Inbox" for a
    /// conversation not in the Inbox (`InboxMove.offered`).
    func symbol(isUnread: Bool, movesToInbox: Bool = false) -> String {
        switch self {
        case .archive: return movesToInbox ? "tray.and.arrow.down" : "archivebox"
        case .trash: return "trash"
        case .toggleRead: return isUnread ? "envelope.open" : "envelope.badge"
        case .snooze: return "clock"
        }
    }

    /// UI-test identifier: the archive slot is `moveToInbox` while it
    /// shows that action.
    func identifier(movesToInbox: Bool = false) -> String {
        self == .archive && movesToInbox ? "moveToInbox" : rawValue
    }

    /// Tooltip and VoiceOver label. "Trash" as everywhere else in the app.
    func title(isUnread: Bool, movesToInbox: Bool = false) -> String {
        switch self {
        case .archive: return movesToInbox ? InboxMove.title : "Archive"
        case .trash: return "Trash"
        case .toggleRead: return isUnread ? "Mark as read" : "Mark as unread"
        case .snooze: return "Snooze"
        }
    }
}

/// The icon buttons of the bulk bar above the list (several rows checked), in
/// order: archive, trash, star, read/unread. The glyphs are the ones the row
/// hover actions and the conversation toolbar already use. `flag` is the state
/// the click acts on (see `SelectionBarState`). The raw value is the UI-test id.
/// New actions (move to inbox, spam, snooze, labels) are new cases here.
enum SelectionBarAction: String, CaseIterable {
    case archive, trash, star, toggleRead

    func symbol(flag: Bool) -> String {
        switch self {
        case .archive: return ThreadRowHoverAction.archive.symbol(isUnread: flag)
        case .trash: return ThreadRowHoverAction.trash.symbol(isUnread: flag)
        case .star: return flag ? "star" : "star.fill"
        case .toggleRead: return ThreadRowHoverAction.toggleRead.symbol(isUnread: flag)
        }
    }

    /// Tooltip (before the shortcut) and VoiceOver label.
    func title(flag: Bool) -> String {
        switch self {
        case .archive: return "Archive"
        case .trash: return "Trash"
        case .star: return flag ? "Star" : "Unstar"
        case .toggleRead: return ThreadRowHoverAction.toggleRead.title(isUnread: flag)
        }
    }

    /// `.help` text: the name, "selected" (not for the read toggle: "Mark as
    /// read" says it), and the shortcut when there is one.
    func tooltip(flag: Bool, shortcut: String?) -> String {
        let base = self == .toggleRead ? title(flag: flag) : "\(title(flag: flag)) selected"
        return shortcut.map { "\(base) (\($0))" } ?? base
    }
}

/// What the bar's buttons act on, computed once per body from the checked
/// rows the store would act on (`actionableCheckedThreads`).
struct SelectionBarState: Equatable {
    /// Star clicks star (some row is unstarred) rather than unstar.
    let starring: Bool
    /// Read clicks mark read (some row is unread) rather than unread.
    let anyUnread: Bool
    /// Some checked row can be acted on. None: every checked row is a Trash
    /// copy of a live conversation, and a click only shows a notice.
    let canAct: Bool
    /// Some checked row is not in the Trash yet (`trashChecked` skips the rest).
    let canTrash: Bool

    init(actionable: [MailThread]) {
        starring = actionable.isEmpty || actionable.contains { !$0.isStarred }
        anyUnread = actionable.contains { $0.isUnread }
        canAct = !actionable.isEmpty
        canTrash = actionable.contains { !$0.inTrash }
    }

    func flag(for action: SelectionBarAction) -> Bool {
        action == .star ? starring : anyUnread
    }

    func isEnabled(_ action: SelectionBarAction) -> Bool {
        action == .trash ? canTrash : canAct
    }
}

/// Size of the bar's buttons: a square hit target, wider than the row's tight
/// hover buttons, the same for every glyph.
enum SelectionBarLayout {
    static let minSide = 24.0
    static let spacing = 6.0

    static func side(fontScale: Double) -> Double {
        max(minSide, ThreadRowActionLayout.iconSize * fontScale + 10)
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
