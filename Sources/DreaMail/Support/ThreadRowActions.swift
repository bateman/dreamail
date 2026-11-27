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

/// The icon buttons of the bulk bar above the list (several rows checked),
/// in Gmail web's toolbar order: archive (or move to inbox), report spam (or
/// not spam), trash; read/unread, snooze; move to, label as; then the app's
/// own star (Gmail keeps "Add star" under More). `SelectionBarState.actions`
/// picks one of each pair. The glyphs are `ThreadRowMenuItem`'s (one action,
/// one glyph, DEC-088); spam has no menu item and keeps the conversation
/// toolbar's glyphs. `flag` is the state the click acts on (see
/// `SelectionBarState`). The raw value is the UI-test id.
enum SelectionBarAction: String, CaseIterable {
    case archive, moveToInbox, reportSpam, notSpam, trash, toggleRead, snooze, moveTo, labelAs, star

    /// The conversation toolbar's spam glyphs (`ThreadDetailToolbar`).
    static let reportSpamSymbol = "exclamationmark.octagon"
    static let notSpamSymbol = "tray"

    func symbol(flag: Bool) -> String {
        switch self {
        case .archive: return ThreadRowMenuItem.archive.symbol
        case .moveToInbox: return ThreadRowMenuItem.moveToInbox.symbol
        case .reportSpam: return Self.reportSpamSymbol
        case .notSpam: return Self.notSpamSymbol
        case .trash: return ThreadRowMenuItem.delete.symbol
        case .toggleRead: return (flag ? ThreadRowMenuItem.markRead : .markUnread).symbol
        case .snooze: return ThreadRowMenuItem.snooze.symbol
        case .moveTo: return ThreadRowMenuItem.moveTo.symbol
        case .labelAs: return ThreadRowMenuItem.labelAs.symbol
        case .star: return (flag ? ThreadRowMenuItem.star : .unstar).symbol
        }
    }

    /// Tooltip (before the shortcut), VoiceOver label and More menu item.
    func title(flag: Bool) -> String {
        switch self {
        case .archive: return "Archive"
        case .moveToInbox: return InboxMove.title
        case .reportSpam: return "Report spam"
        case .notSpam: return "Not spam"
        case .trash: return "Trash"
        case .toggleRead: return ThreadRowHoverAction.toggleRead.title(isUnread: flag)
        case .snooze: return "Snooze"
        // They open a picker: the ellipsis, as in the row menu.
        case .moveTo: return ThreadRowMenuItem.moveTo.title()
        case .labelAs: return ThreadRowMenuItem.labelAs.title()
        case .star: return flag ? "Star" : "Unstar"
        }
    }

    /// `.help` text: the name, "selected" for archive, trash and star (the
    /// other names read as commands already), and the shortcut when bound.
    func tooltip(flag: Bool, shortcut: String?) -> String {
        let selected: Set<SelectionBarAction> = [.archive, .trash, .star]
        let base = selected.contains(self) ? "\(title(flag: flag)) selected" : title(flag: flag)
        return shortcut.map { "\(base) (\($0))" } ?? base
    }
}

/// What the bar's buttons act on, computed once per body from the checked
/// rows still in the list (`checked`) and those the store would act on
/// (`actionable`: without Trash copies of live conversations, DEC-081).
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
    /// The archive slot is "Move to inbox" (`InboxMove.offered`: every row
    /// offers it; a mix keeps Archive, as the palette and the keys do).
    let movesToInbox: Bool
    /// Every row is spam: the spam slot is "Not spam" (`markSpamChecked`).
    let allSpam: Bool
    /// Some row is more than a lone draft: archive, spam and snooze have
    /// mail to act on.
    let hasMail: Bool
    /// Some row is not snoozed in Gmail (`snoozeChecked` leaves those to Gmail).
    let canSnooze: Bool
    /// Some checked row is still in the list: Move to also restores Trash
    /// copies (`moveThreads`).
    let canMove: Bool

    init(actionable: [MailThread], checked: [MailThread]? = nil) {
        starring = actionable.isEmpty || actionable.contains { !$0.isStarred }
        anyUnread = actionable.contains { $0.isUnread }
        canAct = !actionable.isEmpty
        canTrash = actionable.contains { !$0.inTrash }
        movesToInbox = InboxMove.offered(for: actionable)
        allSpam = !actionable.isEmpty && actionable.allSatisfy(\.inSpam)
        hasMail = actionable.contains { !InboxMove.isDraftOnly($0) }
        canSnooze = actionable.contains { !$0.gmailSnoozed && !InboxMove.isDraftOnly($0) }
        canMove = !(checked ?? actionable).isEmpty
    }

    /// The buttons, in order: one of each pair.
    var actions: [SelectionBarAction] {
        SelectionBarAction.allCases.filter { action in
            switch action {
            case .archive: return !movesToInbox
            case .moveToInbox: return movesToInbox
            case .reportSpam: return !allSpam
            case .notSpam: return allSpam
            default: return true
            }
        }
    }

    func flag(for action: SelectionBarAction) -> Bool {
        action == .star ? starring : anyUnread
    }

    /// Off when the click would do nothing, or only show a notice.
    func isEnabled(_ action: SelectionBarAction) -> Bool {
        switch action {
        case .trash: return canTrash
        case .archive, .moveToInbox, .reportSpam, .notSpam: return canAct && hasMail
        case .snooze: return canSnooze
        case .moveTo: return canMove
        case .toggleRead, .labelAs, .star: return canAct
        }
    }
}

/// Size of the bar's buttons (a square hit target, wider than the row's tight
/// hover buttons, the same for every glyph) and how many of them fit.
enum SelectionBarLayout {
    static let minSide = 24.0
    static let spacing = 6.0
    /// The bar's own layout: 12 pt padding each side, 10 pt between its
    /// items (count, hint, spacer, buttons, close), the spacer at least 8 pt.
    static let padding = 12.0
    static let itemSpacing = 10.0
    static let minSpacer = 8.0

    static func side(fontScale: Double) -> Double {
        max(minSide, ThreadRowActionLayout.iconSize * fontScale + 10)
    }

    /// Width of `n` buttons in a row.
    static func stripWidth(_ n: Int, side: Double) -> Double {
        n <= 0 ? 0 : Double(n) * side + Double(n - 1) * spacing
    }

    struct Fit: Equatable {
        /// The first `visible` actions are buttons; the rest go under More.
        let visible: Int
        let showsMore: Bool
        let showsHint: Bool
    }

    /// Gmail's rule when space is short: the trailing actions move under a
    /// More (⋮) menu. "esc to clear" goes first, the count never: it keeps
    /// its full width. `barWidth` 0 (not measured yet): everything shows.
    static func fit(actions n: Int, barWidth: Double, countWidth: Double,
                    hintWidth: Double, closeWidth: Double, side: Double) -> Fit {
        func needed(buttons: Int, hint: Bool) -> Double {
            let items = hint ? 5.0 : 4.0
            return 2 * padding + countWidth + (hint ? hintWidth : 0) + minSpacer
                + stripWidth(buttons, side: side) + closeWidth + (items - 1) * itemSpacing
        }
        guard barWidth > 0 else { return Fit(visible: n, showsMore: false, showsHint: true) }
        if needed(buttons: n, hint: true) <= barWidth {
            return Fit(visible: n, showsMore: false, showsHint: true)
        }
        if needed(buttons: n, hint: false) <= barWidth {
            return Fit(visible: n, showsMore: false, showsHint: false)
        }
        // k buttons and the More button.
        var k = n - 1
        while k > 0 && needed(buttons: k + 1, hint: false) > barWidth { k -= 1 }
        return Fit(visible: k, showsMore: true, showsHint: false)
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
