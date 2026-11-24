import AppKit

/// NSTextView that can check spelling against an explicit set of languages
/// (Settings ▸ Spelling and grammar ▸ Check spelling in) for this view only.
/// Base class of the compose body, subject and snippet editors.
///
/// With `spellLanguages` nil (automatic) every override below forwards to
/// AppKit unchanged. With a set, AppKit's own incremental checking still
/// does the work: each range it is about to check is split into paragraph
/// runs, each run is checked with the orthography of the chosen language it
/// reads as, and a spelling mark is dropped when the word is correct in any
/// chosen language. Nothing global is changed: not
/// `NSSpellChecker.shared.language()`, not "Automatic by Language", not other
/// apps' settings. Check Document Now (⌘;) and the Spelling panel are
/// AppKit's and keep following the system language.
class MultilingualSpellTextView: NSTextView {
    /// Nil: the system setting decides. Otherwise the resolved, non-empty
    /// set from `ComposeSpellLanguages.resolve`.
    var spellLanguages: [String]? {
        didSet {
            guard spellLanguages != oldValue else { return }
            spellLookups.removeAll()
            guard isContinuousSpellCheckingEnabled else { return }
            // Re-mark the whole text under the new rule; AppKit re-checks
            // what is visible and the rest as it scrolls into view.
            isContinuousSpellCheckingEnabled = false
            isContinuousSpellCheckingEnabled = true
        }
    }
    var spellLanguageChecker: SpellLanguageChecking = SystemSpellLanguageChecker() {
        didSet { spellLookups.removeAll() }
    }
    var spellLanguageIdentifier: SpellLanguageIdentifying = NaturalLanguageSpellIdentifier()
    /// Per-view answers of the "correct in another chosen language" lookups.
    let spellLookups = SpellLookupCache()

    /// The longest word the right-click suggestions are computed for; past
    /// it (a pasted token, a URL without spaces) AppKit's menu stays as is.
    static let maxSuggestedWordLength = 100

    private static let spellingType = NSTextCheckingResult.CheckingType.spelling.rawValue
    private static let grammarType = NSTextCheckingResult.CheckingType.grammar.rawValue
    private static let orthographyType = NSTextCheckingResult.CheckingType.orthography.rawValue

    /// The text storage's own string: no copy per check.
    private var currentText: NSString {
        textStorage?.mutableString ?? (string as NSString)
    }

    override func checkText(in range: NSRange, types checkingTypes: NSTextCheckingTypes,
                            options: [NSSpellChecker.OptionKey: Any] = [:]) {
        guard let languages = spellLanguages, !languages.isEmpty,
              checkingTypes & Self.spellingType != 0 else {
            forwardCheck(in: range, types: checkingTypes, options: options)
            return
        }
        // The orthography is given, so AppKit must not detect another one.
        let types = checkingTypes & ~Self.orthographyType
        for run in ComposeSpellLanguages.runs(in: currentText, range: range,
                                              languages: languages,
                                              identifier: spellLanguageIdentifier) {
            var runOptions = options
            runOptions[.orthography] = NSOrthography.defaultOrthography(forLanguage: run.language)
            forwardCheck(in: run.range,
                         types: run.isCapped ? types & ~Self.grammarType : types,
                         options: runOptions)
        }
    }

    /// AppKit's checking for one run; separate so tests can see the runs.
    func forwardCheck(in range: NSRange, types: NSTextCheckingTypes,
                      options: [NSSpellChecker.OptionKey: Any]) {
        super.checkText(in: range, types: types, options: options)
    }

    override func handleTextCheckingResults(_ results: [NSTextCheckingResult],
                                            forRange range: NSRange,
                                            types checkingTypes: NSTextCheckingTypes,
                                            options: [NSSpellChecker.OptionKey: Any] = [:],
                                            orthography: NSOrthography,
                                            wordCount: Int) {
        super.handleTextCheckingResults(
            filteredCheckingResults(results, checkedIn: orthography.dominantLanguage,
                                    offset: range.location),
            forRange: range, types: checkingTypes, options: options,
            orthography: orthography, wordCount: wordCount)
    }

    /// The results AppKit will mark, after the "correct in any chosen
    /// language" rule. `checkedIn` is the language AppKit says it checked
    /// in (the orthography it hands back), which flagged the words already.
    /// Result ranges are relative to the checked range, which starts at
    /// `offset` (proven against real AppKit by the continuous-checking test).
    func filteredCheckingResults(_ results: [NSTextCheckingResult],
                                 checkedIn: String? = nil,
                                 offset: Int = 0) -> [NSTextCheckingResult] {
        guard let languages = spellLanguages, !languages.isEmpty else { return results }
        return ComposeSpellLanguages.filter(results, in: currentText, offset: offset,
                                            languages: languages,
                                            checkedLanguage: checkedIn,
                                            documentTag: spellCheckerDocumentTag,
                                            checker: spellLanguageChecker,
                                            cache: spellLookups)
    }

    override func ignoreSpelling(_ sender: Any?) {
        super.ignoreSpelling(sender)
        spellLookups.removeAll()
    }

    // MARK: Suggestions

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let menu, spellLanguages != nil else { return menu }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        replaceSpellingGuesses(in: menu, atCharacterIndex: index)
        routeLearnAndIgnore(in: menu)
        return menu
    }

    /// Puts suggestions from the chosen languages, the paragraph's language
    /// first, in place of AppKit's (which come from one language). Leaves
    /// the menu alone unless it has a suggestion section and the word under
    /// the pointer is misspelled in every chosen language.
    @discardableResult
    func replaceSpellingGuesses(in menu: NSMenu, atCharacterIndex index: Int) -> Bool {
        guard let languages = spellLanguages, !languages.isEmpty,
              let guessItems = ComposeSpellLanguages.spellingGuessItems(in: menu),
              let wordRange = clickedWordRange(atCharacterIndex: index) else { return false }
        let text = currentText
        let word = text.substring(with: wordRange)
        let tag = spellCheckerDocumentTag
        guard !languages.contains(where: {
            spellLanguageChecker.isCorrect(word, language: $0, documentTag: tag)
        }) else { return false }
        let paragraph = text.paragraphRange(for: wordRange)
        let sample = NSRange(location: paragraph.location,
                             length: min(paragraph.length, ComposeSpellLanguages.identificationSample))
        let paragraphLanguage = spellLanguageIdentifier.dominantLanguage(
            of: text.substring(with: sample), among: languages)
        let guesses = ComposeSpellLanguages.guesses(
            for: word, paragraphLanguage: paragraphLanguage, languages: languages,
            documentTag: tag, checker: spellLanguageChecker)
        // No suggestions in any chosen language: AppKit's "No Guesses Found"
        // (or its own guesses) stays.
        guard !guesses.isEmpty else { return false }
        for i in guessItems.reversed() { menu.removeItem(at: i) }
        for (offset, guess) in guesses.enumerated() {
            let item = NSMenuItem(title: guess, action: #selector(applySpellingGuess(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = SpellingGuessChoice(range: wordRange, word: word,
                                                         replacement: guess)
            menu.insertItem(item, at: offset)
        }
        return true
    }

    /// The word the menu is about: AppKit's selection when the right-click
    /// selected it (and the click is in it), else the word at the click.
    /// Nil past `maxSuggestedWordLength`.
    func clickedWordRange(atCharacterIndex index: Int) -> NSRange? {
        let text = currentText
        let selection = selectedRange()
        let range: NSRange
        if selection.length > 0, selection.location != NSNotFound,
           NSMaxRange(selection) <= text.length,
           index >= selection.location, index <= NSMaxRange(selection) {
            range = selection
        } else if let word = wordRange(atCharacterIndex: index) {
            range = word
        } else {
            return nil
        }
        guard range.length <= Self.maxSuggestedWordLength else { return nil }
        return range
    }

    private func wordRange(atCharacterIndex index: Int) -> NSRange? {
        let text = currentText
        guard text.length > 0 else { return nil }
        let letters = CharacterSet.letters
        func isLetter(_ i: Int) -> Bool {
            guard i >= 0, i < text.length,
                  let scalar = UnicodeScalar(text.character(at: i)) else { return false }
            return letters.contains(scalar)
        }
        // The insertion index sits between characters: take the letter on
        // either side of it.
        let probe = isLetter(index) ? index : (isLetter(index - 1) ? index - 1 : nil)
        guard let probe else { return nil }
        let range = selectionRange(forProposedRange: NSRange(location: probe, length: 0),
                                   granularity: .selectByWord)
        guard range.location != NSNotFound, range.length > 0,
              NSMaxRange(range) <= text.length else { return nil }
        return range
    }

    @objc func applySpellingGuess(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? SpellingGuessChoice else { return }
        let text = currentText
        // The text may have changed while the menu was open.
        guard NSMaxRange(choice.range) <= text.length,
              text.substring(with: choice.range) == choice.word,
              shouldChangeText(in: choice.range, replacementString: choice.replacement)
        else { return }
        textStorage?.replaceCharacters(in: choice.range, with: choice.replacement)
        didChangeText()
    }

    // MARK: Learn / Ignore

    /// AppKit's own Learn, Unlearn and Ignore items, re-pointed here so the
    /// lookup cache is emptied around them. The original action still runs,
    /// with the same sender. Items of any other kind are untouched.
    private var spellingMenuActions: [ObjectIdentifier: (action: Selector, target: AnyObject?)] = [:]

    func routeLearnAndIgnore(in menu: NSMenu) {
        spellingMenuActions.removeAll()
        for item in menu.items {
            guard let action = item.action, action != #selector(applySpellingGuess(_:)) else { continue }
            let name = NSStringFromSelector(action).lowercased()
            guard name.contains("learnspelling") || name.contains("ignorespelling") else { continue }
            spellingMenuActions[ObjectIdentifier(item)] = (action, item.target)
            item.target = self
            item.action = #selector(runSpellingMenuAction(_:))
        }
    }

    @objc func runSpellingMenuAction(_ sender: NSMenuItem) {
        guard let original = spellingMenuActions[ObjectIdentifier(sender)] else { return }
        spellLookups.removeAll()
        let target: AnyObject = original.target ?? self
        if target.responds(to: original.action) {
            _ = target.perform(original.action, with: sender)
        } else {
            NSApplication.shared.sendAction(original.action, to: original.target, from: sender)
        }
        spellLookups.removeAll()
    }
}

final class SpellingGuessChoice: NSObject {
    let range: NSRange
    let word: String
    let replacement: String
    init(range: NSRange, word: String, replacement: String) {
        self.range = range
        self.word = word
        self.replacement = replacement
    }
}
