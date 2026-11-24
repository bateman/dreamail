import Foundation

/// When the main window's key monitor may run a mailbox single key (the
/// rebindable commands, the `g` / `*` sequences, `/`, `?`, arrows, Return,
/// Space). Pure so the "never while typing" rule is testable without a
/// window: ContentView feeds it the live facts.
enum MailboxKeyGate {
    struct Facts: Equatable {
        /// No ⌘ / ⌥ / ⌃ held (Shift is allowed: `#`, `!`, `?`, `*`, ⇧I…).
        var unmodified: Bool
        /// The event belongs to the main window, not Settings or a panel.
        var isMainWindow: Bool
        var commandPaletteOpen: Bool
        var labelPickerOpen: Bool
        var viewEditorOpen: Bool
        var hasComposeRequest: Bool
        var composeMinimized: Bool
        var composeFinishing: Bool
        /// `TextFocus.isEditing(firstResponder)`: an editable field or text
        /// view (search, compose, label query, Settings) owns the keyboard.
        var textEditing: Bool
    }

    static func allowsSingleKeys(_ facts: Facts) -> Bool {
        guard facts.unmodified,
              facts.isMainWindow,
              !facts.commandPaletteOpen,
              !facts.labelPickerOpen,
              !facts.viewEditorOpen,
              ComposeKeyOwnership.allowsMailboxKeys(
                  hasRequest: facts.hasComposeRequest,
                  minimized: facts.composeMinimized,
                  finishing: facts.composeFinishing)
        else { return false }
        // Only *editable* text stands the keys down; selectable read-only
        // conversation text must not (see TextFocus). Mid-finish bypasses
        // this (see ComposeKeyOwnership.textFocusBlocksMailboxKeys).
        return !(facts.textEditing
                 && ComposeKeyOwnership.textFocusBlocksMailboxKeys(
                     finishing: facts.composeFinishing))
    }
}

/// Gmail's `u`, "back to threadlist": what it does depends on how the
/// conversation is showing.
enum BackToList {
    enum Action: Equatable {
        /// Full-window (or centered-card) conversation: return to the list.
        case exitThreadFocus
        /// Narrow window: the conversation covers the list; close it.
        case closeConversation
        /// The list is already on screen (reading pane, or no conversation).
        case stay
    }

    static func action(layoutMode: MailLayoutMode,
                       threadFocus: Bool) -> Action {
        if threadFocus { return .exitThreadFocus }
        switch layoutMode {
        case .threadFocus: return .exitThreadFocus
        case .compactDetail: return .closeConversation
        case .list, .threePane: return .stay
        }
    }
}
