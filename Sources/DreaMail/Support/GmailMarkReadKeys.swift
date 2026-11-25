import Foundation

/// Gmail's mark-read / mark-unread chords: **Shift+I** and **Shift+U**.
///
/// These are fixed (not rebindable). `KeyBindings` only owns single keys
/// without modifiers; the app's `u` toggle remains a separate, rebindable
/// command. ContentView consults this before the single-key registry so a
/// held Shift is not lowercased into a no-op (or a wrong command).
///
/// As in Gmail, Shift+I always marks read and Shift+U always marks unread.
/// The read / unread toggle is the separate `toggleRead` command.
enum GmailMarkReadKeys {
    enum Chord: Equatable {
        /// Shift+I — mark read, or mark unread when already fully read.
        case shiftI
        /// Shift+U — always mark unread.
        case shiftU
    }

    /// - Parameters:
    ///   - key: `NSEvent.charactersIgnoringModifiers` (Shift still affects
    ///     letters, so callers may pass `"I"` / `"U"`).
    ///   - shiftOnly: Shift held, and no ⌘ / ⌥ / ⌃.
    static func chord(key: String, shiftOnly: Bool) -> Chord? {
        guard shiftOnly, key.count == 1 else { return nil }
        switch key.lowercased() {
        case "i": return .shiftI
        case "u": return .shiftU
        default: return nil
        }
    }

    /// Desired `read` flag for `setRead` given the chord.
    static func desiredRead(chord: Chord) -> Bool {
        switch chord {
        case .shiftI: return true
        case .shiftU: return false
        }
    }
}

/// Gmail's Shift+N, "update conversation": DreaMail syncs every account
/// (the same action as ⌘⇧R). Fixed, consulted before the single-key
/// registry like the read chords (which would lowercase it to `n`).
enum GmailRefreshKey {
    static func matches(key: String, shiftOnly: Bool) -> Bool {
        shiftOnly && key.count == 1 && key.lowercased() == "n"
    }
}
