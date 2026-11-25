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
