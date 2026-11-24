import AppKit

/// Apple's system spelling and grammar checking for the writing surfaces
/// (compose body, subject, snippet editor). The checker itself is
/// NSSpellChecker — the same one Mail and TextEdit use, with the user's
/// language and learned words — so this only decides which checks are on.
///
/// Both default to on. The settings are global; Edit ▸ Spelling and Grammar
/// can still flip one view for the current editing session. Which languages
/// are checked is `ComposeSpellLanguages` (automatic unless chosen).
enum ComposeSpellCheck {
    static let spellingKey = "composeSpellCheck"
    static let grammarKey = "composeGrammarCheck"

    struct Options: Equatable {
        var spelling: Bool
        var grammar: Bool
        /// The stored `ComposeSpellLanguages` value: empty means automatic.
        /// Kept raw so comparing options on every view update stays cheap;
        /// it is resolved against the installed languages only in `apply`.
        var languages: String = ""
    }

    /// Current settings. A missing key means on: users who never opened
    /// Settings still get red underlines.
    static func options(from defaults: UserDefaults = .standard) -> Options {
        Options(spelling: defaults.object(forKey: spellingKey) as? Bool ?? true,
                grammar: defaults.object(forKey: grammarKey) as? Bool ?? true,
                languages: defaults.string(forKey: ComposeSpellLanguages.storageKey) ?? "")
    }

    /// Turns the checks on or off for one text view. Grammar marks only
    /// show while spelling is on (AppKit checks both in the same pass), so
    /// grammar follows spelling off.
    static func apply(_ options: Options, to textView: NSTextView) {
        let grammar = options.spelling && options.grammar
        // Languages first, so turning spelling on below checks once, under
        // the right rule. A plain NSTextView always follows the system.
        if let view = textView as? MultilingualSpellTextView {
            let languages = ComposeSpellLanguages.resolve(stored: options.languages,
                                                          checker: view.spellLanguageChecker)
            if view.spellLanguages != languages {
                view.spellLanguages = languages
            }
        }
        // Mark only, never rewrite. A new NSTextView takes the system
        // "Correct spelling automatically" setting, so turn it off here for
        // every writing surface (body, subject, snippet editor).
        if textView.isAutomaticSpellingCorrectionEnabled {
            textView.isAutomaticSpellingCorrectionEnabled = false
        }
        if textView.isContinuousSpellCheckingEnabled != options.spelling {
            textView.isContinuousSpellCheckingEnabled = options.spelling
        }
        if textView.isGrammarCheckingEnabled != grammar {
            textView.isGrammarCheckingEnabled = grammar
        }
    }
}
