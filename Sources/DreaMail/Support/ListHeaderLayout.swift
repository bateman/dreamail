import CoreGraphics

/// A button of the window's toolbar group (`ContentView`'s `.toolbar`).
enum WindowToolbarButton: Equatable {
    case paneToggle, focus, askAI
}

/// Pure layout rule of the list column's top bar (`ListHeaderBar`): what the
/// row must clear at its leading edge, and what gives way when the column is
/// narrow.
///
/// Order in which things give way, as the column narrows:
/// 1. The reserve for the window's own buttons is only counted for buttons
///    really over the row (see `buttonsOverRow`): none in three panes.
/// 2. "Search all of Gmail" loses its text and stays an icon.
/// 3. The field shrinks from its preferred minimum (150 pt) to a hard minimum
///    (100 pt).
/// 4. The title is the last: its guaranteed width shrinks from 48 pt to 28 pt;
///    beyond that it truncates with an ellipsis, and never disappears.
enum ListHeaderLayout {
    static let leadingPadding: CGFloat = 14
    static let trailingPadding: CGFloat = 10
    static let iconWidth: CGFloat = 20
    static let spacing: CGFloat = 8
    /// Width of one window toolbar button (measured: 45 and 41 pt).
    static let buttonWidth: CGFloat = 45
    /// The system's sidebar toggle, when it sits at the row's leading edge
    /// (sidebar collapsed). An estimate: not measured.
    static let sidebarToggleWidth: CGFloat = 45
    static let searchAllIconWidth: CGFloat = 28
    static let searchAllTextExtra: CGFloat = 100
    static let fieldMaxWidth: CGFloat = 380
    static let fieldPreferredMinWidth: CGFloat = 150
    static let fieldHardMinWidth: CGFloat = 100
    /// Field width from which "Search all of Gmail" shows its text.
    static let fieldComfortableWidth: CGFloat = 260
    static let titleMinWidth: CGFloat = 48
    static let titleHardMinWidth: CGFloat = 28

    /// The buttons of the window's toolbar group, in order. The one
    /// description `ContentView`'s toolbar is built from.
    static func windowButtons(fullWindowThreads: Bool, askAIEnabled: Bool) -> [WindowToolbarButton] {
        var buttons: [WindowToolbarButton] = []
        // Full-window style has no reading pane to toggle.
        if !fullWindowThreads { buttons.append(.paneToggle) }
        buttons.append(.focus)
        // No Ask AI button in a build without AI features.
        if askAIEnabled { buttons.append(.askAI) }
        return buttons
    }

    /// Whether the window's buttons sit over the list column's row: macOS puts
    /// the group at the leading edge of the window's last column, which is the
    /// list only when it is the detail column (the `.list` layout).
    static func windowButtonsOverRow(mode: MailLayoutMode) -> Bool {
        mode == .list
    }

    /// Room to leave at the row's leading edge.
    static func leadingReserve(buttonsOverRow: [WindowToolbarButton],
                               sidebarToggleOverRow: Bool) -> CGFloat {
        var reserve: CGFloat = 0
        if !buttonsOverRow.isEmpty { reserve += CGFloat(buttonsOverRow.count) * buttonWidth + 10 }
        if sidebarToggleOverRow { reserve += sidebarToggleWidth }
        return reserve
    }

    struct Result: Equatable {
        var reserve: CGFloat
        var showsSearchAllText: Bool
        var fieldMinWidth: CGFloat
        var fieldMaxWidth: CGFloat
        var titleMinWidth: CGFloat
    }

    static func resolve(columnWidth: CGFloat,
                        buttonsOverRow: [WindowToolbarButton],
                        sidebarToggleOverRow: Bool,
                        searching: Bool) -> Result {
        let reserve = leadingReserve(buttonsOverRow: buttonsOverRow,
                                     sidebarToggleOverRow: sidebarToggleOverRow)
        // What is left for the field once icon, title (at its guaranteed
        // width), paddings, reserve and the gaps are placed.
        var free = columnWidth - leadingPadding - trailingPadding - reserve
            - iconWidth - spacing - titleMinWidth - spacing
        if searching { free -= searchAllIconWidth + spacing }
        var showsText = false
        if searching, free - searchAllTextExtra >= fieldComfortableWidth {
            showsText = true
            free -= searchAllTextExtra
        }
        let fieldMin = min(max(free, fieldHardMinWidth), fieldPreferredMinWidth)
        // Still short: the title gives up part of its guaranteed width.
        let shortfall = max(0, fieldHardMinWidth - free)
        let title = max(titleHardMinWidth, titleMinWidth - shortfall)
        return Result(reserve: reserve, showsSearchAllText: showsText,
                      fieldMinWidth: fieldMin, fieldMaxWidth: fieldMaxWidth,
                      titleMinWidth: title)
    }
}
