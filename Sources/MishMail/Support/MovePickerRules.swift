import Foundation

/// Which conversations Gmail's "Move to" acts on, and when a label created
/// from the picker may still be applied. Pure; `MailStore` holds the state.
enum MovePickerRules {
    /// The conversations fixed when the picker opens. The conversation
    /// toolbar passes its own conversation and wins; the key, menu and
    /// palette act on the checked rows, else the focused one.
    static func targetIds(toolbarThread: String?, checkedInOrder: [String],
                          focused: String?) -> [String] {
        if let toolbarThread { return [toolbarThread] }
        if !checkedInOrder.isEmpty { return checkedInOrder }
        return focused.map { [$0] } ?? []
    }

    /// A label created from the picker is applied only if the same picker
    /// session is still open in move mode when Gmail answers.
    static func appliesCreatedLabel(pickerOpen: Bool, moveMode: Bool,
                                    currentSession: UUID, requestSession: UUID) -> Bool {
        pickerOpen && moveMode && currentSession == requestSession
    }
}

/// Gmail's label picker keys: Return applies the highlighted label and
/// closes; Space and clicks toggle without closing. Pure.
enum LabelPickerKeyRules {
    /// Whether the picker closes after a label row was applied by a key.
    /// Move mode closes itself in `moveThreads`; label mode closes on Return.
    static func closesAfterApply(moveMode: Bool, closeKey: Bool) -> Bool {
        !moveMode && closeKey
    }

    /// Whether Return toggles the highlighted label. Once a box was changed in
    /// this opening (label mode), Return only closes: it must not undo the pick.
    static func returnTogglesLabel(moveMode: Bool, changed: Bool) -> Bool {
        moveMode || !changed
    }

    /// The footer's key hints for the highlighted row.
    static func footerHints(moveMode: Bool, onCreateRow: Bool) -> [String] {
        if onCreateRow { return ["↑↓ select", "↵ create", "esc close"] }
        return moveMode
            ? ["↑↓ select", "↵ move", "esc close"]
            : ["↑↓ select", "↵ apply and close", "space toggle", "esc close"]
    }
}
