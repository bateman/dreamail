import CoreGraphics

/// Widths of the search field, a flexible toolbar item of the list column
/// (`ListSearchToolbar`). Whether the system really narrows the field to
/// `fieldMinWidth` before moving anything into the » overflow menu is not
/// assumed: `ListSearchFieldUITests` measures the field's width and the
/// toolbar's items at the window's minimum size.
enum ListHeaderLayout {
    static let fieldMinWidth: CGFloat = 140
    static let fieldIdealWidth: CGFloat = 260
    static let fieldMaxWidth: CGFloat = 380
}
