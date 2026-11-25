import Foundation

/// The ⌘ formatting chords of the compose body (a Markdown editor), and how
/// they line up with Gmail's formatting shortcuts. Pure, so the table the
/// editor runs and the one the `?` help shows are the same and tested.
enum ComposeFormatKeys {
    enum Format: Equatable {
        case bold, italic, strikethrough, code, math
        case heading1, heading2, heading3
        case bullet, quote
    }

    /// kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_Period: positions, not characters,
    /// so ⌘⇧8 / ⌘⇧9 work on layouts where Shift+8 is not `*` (Italian: `(`).
    static let keyCode8: UInt16 = 28
    static let keyCode9: UInt16 = 25
    static let keyCodePeriod: UInt16 = 47

    /// The format a chord runs, or nil to leave it to the text system.
    /// - Parameters:
    ///   - characters: `charactersIgnoringModifiers`.
    ///   - command/shift/option/control: the held modifiers.
    static func format(keyCode: UInt16, characters: String,
                       command: Bool, shift: Bool, option: Bool, control: Bool) -> Format? {
        guard command, !control else { return nil }
        if shift, !option {
            switch keyCode {
            case keyCode8: return .bullet                  // Gmail ⌘⇧8
            case keyCode9, keyCodePeriod: return .quote    // Gmail ⌘⇧9; ⌘⇧. is DreaMail's
            default: break
            }
        }
        switch (characters.lowercased(), shift, option) {
        case ("b", false, false): return .bold             // Gmail ⌘B
        case ("i", false, false): return .italic           // Gmail ⌘I
        case ("x", true, false): return .strikethrough
        case ("e", false, false): return .code
        case ("m", true, false): return .math
        case ("1", false, true): return .heading1
        case ("2", false, true): return .heading2
        case ("3", false, true): return .heading3
        default: return nil
        }
    }

    /// Gmail's formatting shortcuts (support.google.com/mail/answer/6594,
    /// Mac). `supported`: the compose editor has the action and the chord
    /// runs it. The others need an editor feature DreaMail does not have
    /// (the body is Markdown: no underline, numbered lists, indentation,
    /// alignment or font sizes).
    static let gmailReference: [(keys: String, title: String, supported: Bool)] = [
        ("⌘B", "Bold", true),
        ("⌘I", "Italic", true),
        ("⌘U", "Underline", false),
        ("⌘⇧7", "Numbered list", false),
        ("⌘⇧8", "Bulleted list", true),
        ("⌘⇧9", "Quote", true),
        ("⌘[", "Indent less", false),
        ("⌘]", "Indent more", false),
        ("⌘\\", "Remove formatting", false),
        ("⌘K", "Insert link", true),
    ]
}
