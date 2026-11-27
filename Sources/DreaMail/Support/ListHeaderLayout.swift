import CoreGraphics

/// Sizes of the search field in the list column's toolbar and the widths the
/// bar needs, so that the toolbar never has to move anything into the »
/// overflow menu at any size the window can take.
///
/// The field is a real toolbar item: it narrows from `fieldIdealWidth` to
/// `fieldMinWidth` (the system compresses a flexible item before it overflows
/// anything). The title is the native toolbar title, which truncates.
enum ListHeaderLayout {
    static let fieldMinWidth: CGFloat = 140
    static let fieldIdealWidth: CGFloat = 260
    static let fieldMaxWidth: CGFloat = 380

    // What else shares the list column's bar (estimates, not measured except
    // where noted).
    static let paddings: CGFloat = 20
    static let iconWidth: CGFloat = 20
    /// "Inbox" measured at 36 pt; a label's title truncates beyond this.
    static let titleGuaranteedWidth: CGFloat = 48
    static let searchAllButtonWidth: CGFloat = 36
    /// A window toolbar button: measured 45 and 41 pt.
    static let windowButtonWidth: CGFloat = 45
    /// The system's sidebar toggle: measured 47-48 pt.
    static let sidebarToggleWidth: CGFloat = 48
    /// Spacing between toolbar items.
    static let itemSpacing: CGFloat = 8

    /// Width the list column's bar needs with the field at its minimum.
    static func requiredColumnWidth(searching: Bool) -> CGFloat {
        var width = paddings + iconWidth + itemSpacing + titleGuaranteedWidth
            + itemSpacing + fieldMinWidth
        if searching { width += itemSpacing + searchAllButtonWidth }
        return width
    }

    /// Extra width the bar needs when the window's own button group (pane
    /// toggle, focus, Ask AI) and the sidebar toggle share it: the list is
    /// then the window's last column.
    static func sharedWindowChrome(buttons: Int, sidebarToggle: Bool) -> CGFloat {
        CGFloat(buttons) * windowButtonWidth + (sidebarToggle ? sidebarToggleWidth : 0)
    }
}
