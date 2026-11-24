import AppKit
import XCTest

/// The multilingual spell-check rules, against a fake checker: the CI
/// runner's installed dictionaries are not the user's, so no test here
/// depends on which languages NSSpellChecker has.
final class ComposeSpellLanguagesTests: XCTestCase {

    // MARK: Fakes

    final class FakeChecker: SpellLanguageChecking {
        var availableLanguages: [String]
        var userPreferredLanguages: [String]
        var currentLanguage: String
        /// language → words spelled correctly in it.
        var dictionary: [String: Set<String>]
        /// language → word → suggestions.
        var suggestions: [String: [String: [String]]] = [:]
        /// (word, language, documentTag) for each isCorrect call.
        private(set) var lookups: [(String, String, Int)] = []

        init(available: [String] = ["en", "en_GB", "it", "de", "fr"],
             preferred: [String] = ["en", "it"],
             current: String = "en",
             dictionary: [String: Set<String>] = [:]) {
            availableLanguages = available
            userPreferredLanguages = preferred
            currentLanguage = current
            self.dictionary = dictionary
        }

        func isCorrect(_ word: String, language: String, documentTag: Int) -> Bool {
            lookups.append((word, language, documentTag))
            return dictionary[language]?.contains(word.lowercased()) ?? false
        }

        func guesses(for word: String, language: String, documentTag: Int) -> [String] {
            suggestions[language]?[word] ?? []
        }
    }

    /// Reads a paragraph as Italian when it contains "ciao" or "grazie", as
    /// English when it contains "hello" or "thanks", else cannot tell.
    struct FakeIdentifier: SpellLanguageIdentifying {
        func dominantLanguage(of text: String, among languages: [String]) -> String? {
            let lower = text.lowercased()
            let guess: String?
            if lower.contains("ciao") || lower.contains("grazie") {
                guess = "it"
            } else if lower.contains("hello") || lower.contains("thanks") {
                guess = "en"
            } else {
                guess = nil
            }
            return guess.flatMap { languages.contains($0) ? $0 : nil }
        }
    }

    private let enIt = ["en", "it"]

    // MARK: Persistence and fallback

    func testDecodeDropsBlanksAndRepeats() {
        XCTAssertEqual(ComposeSpellLanguages.decode(" it, en,,it ,"), ["it", "en"])
        XCTAssertEqual(ComposeSpellLanguages.decode(""), [])
        XCTAssertEqual(ComposeSpellLanguages.encode(["it", "en", "it"]), "it,en")
        XCTAssertEqual(ComposeSpellLanguages.decode(ComposeSpellLanguages.encode(["en_GB", "it"])),
                       ["en_GB", "it"])
    }

    func testNothingStoredMeansAutomatic() {
        XCTAssertNil(ComposeSpellLanguages.resolve(stored: "", checker: FakeChecker()))
    }

    func testChosenLanguagesFollowTheSystemPreferredOrder() {
        let checker = FakeChecker(available: ["de", "en", "fr", "it"], preferred: ["it", "en"])
        XCTAssertEqual(ComposeSpellLanguages.resolve(stored: "fr,en,it", checker: checker),
                       ["it", "en", "fr"])
    }

    func testALanguageNoLongerInstalledIsDropped() {
        let checker = FakeChecker(available: ["en", "it"])
        XCTAssertEqual(ComposeSpellLanguages.resolve(stored: "en,nl,it", checker: checker),
                       ["en", "it"])
    }

    func testNoChosenLanguageLeftFallsBackToAutomatic() {
        let checker = FakeChecker(available: ["en", "it"])
        XCTAssertNil(ComposeSpellLanguages.resolve(stored: "nl,sv", checker: checker))
    }

    func testSpecificLanguagesStartFromTheSystemList() {
        XCTAssertEqual(ComposeSpellLanguages.defaultSelection(
            available: ["de", "en", "it"], preferred: ["it", "xx", "en"], current: "de"),
            ["it", "en"])
        XCTAssertEqual(ComposeSpellLanguages.defaultSelection(
            available: ["de", "en"], preferred: [], current: "de"), ["de"])
        XCTAssertEqual(ComposeSpellLanguages.defaultSelection(
            available: ["de", "en"], preferred: [], current: "xx"), ["de"])
        XCTAssertEqual(ComposeSpellLanguages.defaultSelection(
            available: [], preferred: [], current: "en"), [])
    }

    func testNamesAreLocalizedAndBaseCodesIgnoreTheRegion() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(ComposeSpellLanguages.displayName(for: "it", locale: english), "Italian")
        XCTAssertEqual(ComposeSpellLanguages.displayName(for: "it", locale: Locale(identifier: "it_IT")),
                       "italiano")
        XCTAssertEqual(ComposeSpellLanguages.baseLanguage(of: "en_GB"), "en")
        XCTAssertEqual(ComposeSpellLanguages.baseLanguage(of: "pt-BR"), "pt")
        XCTAssertEqual(ComposeSpellLanguages.baseLanguage(of: "it"), "it")
    }

    func testOptionsReadTheStoredLanguages() {
        let suite = "ComposeSpellLanguagesTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ComposeSpellCheck.options(from: defaults).languages, "")
        defaults.set("en,it", forKey: ComposeSpellLanguages.storageKey)
        XCTAssertEqual(ComposeSpellCheck.options(from: defaults),
                       .init(spelling: true, grammar: true, languages: "en,it"))
    }

    // MARK: Correct in any chosen language

    private func spelling(_ text: NSString, _ word: String) -> NSTextCheckingResult {
        .spellCheckingResult(range: text.range(of: word))
    }

    func testAWordCorrectInAnyChosenLanguageIsNotUnderlined() {
        let text = "Ciao Marco, thanks for the draft" as NSString
        let checker = FakeChecker(dictionary: ["en": ["thanks", "draft"], "it": ["ciao"]])
        let results = [spelling(text, "Ciao"), spelling(text, "thanks"), spelling(text, "Marco")]
        let kept = ComposeSpellLanguages.filter(results, in: text, languages: enIt,
                                                documentTag: 7, checker: checker)
        XCTAssertEqual(kept.map(\.range), [text.range(of: "Marco")])
    }

    func testAWordMisspelledInEveryChosenLanguageStaysUnderlined() {
        let text = "Grazie for the dokument" as NSString
        let checker = FakeChecker(dictionary: ["en": ["document"], "it": ["grazie", "documento"]])
        let kept = ComposeSpellLanguages.filter([spelling(text, "dokument")], in: text,
                                                languages: enIt, documentTag: 7, checker: checker)
        XCTAssertEqual(kept.map(\.range), [text.range(of: "dokument")])
    }

    func testOnlyTheChosenLanguagesCount() {
        // Correct in German, which is installed but not chosen.
        let text = "Danke" as NSString
        let checker = FakeChecker(dictionary: ["de": ["danke"]])
        let kept = ComposeSpellLanguages.filter([spelling(text, "Danke")], in: text,
                                                languages: enIt, documentTag: 1, checker: checker)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(Set(checker.lookups.map(\.1)), ["en", "it"])
    }

    func testIgnoredWordsUseTheViewsSpellDocument() {
        // Ignore Spelling is per spell document: the lookups must carry the
        // view's tag, or a word ignored in this message would come back.
        let text = "zorp" as NSString
        let checker = FakeChecker()
        _ = ComposeSpellLanguages.filter([spelling(text, "zorp")], in: text,
                                         languages: enIt, documentTag: 42, checker: checker)
        XCTAssertFalse(checker.lookups.isEmpty)
        XCTAssertTrue(checker.lookups.allSatisfy { $0.2 == 42 })
    }

    func testGrammarAndUnreadableResultsPassThrough() {
        let text = "ciao" as NSString
        let checker = FakeChecker(dictionary: ["it": ["ciao"]])
        let grammar = NSTextCheckingResult.grammarCheckingResult(
            range: NSRange(location: 0, length: 4), details: [])
        let outOfRange = NSTextCheckingResult.spellCheckingResult(
            range: NSRange(location: 2, length: 10))
        let kept = ComposeSpellLanguages.filter([grammar, outOfRange], in: text,
                                                languages: enIt, documentTag: 0, checker: checker)
        XCTAssertEqual(kept.count, 2)
        XCTAssertTrue(checker.lookups.isEmpty)
    }

    func testAutomaticKeepsEveryResult() {
        let view = MultilingualSpellTextView()
        let checker = FakeChecker(dictionary: ["it": ["ciao"]])
        view.spellLanguageChecker = checker
        view.string = "ciao"
        let results = [NSTextCheckingResult.spellCheckingResult(range: NSRange(location: 0, length: 4))]
        XCTAssertEqual(view.filteredCheckingResults(results).count, 1)
        XCTAssertTrue(checker.lookups.isEmpty)

        view.spellLanguages = enIt
        XCTAssertEqual(view.filteredCheckingResults(results).count, 0)
    }

    // MARK: Which language each paragraph is checked in

    private func runs(_ text: String, range: NSRange? = nil,
                      languages: [String]? = nil) -> [ComposeSpellLanguages.CheckRun] {
        let ns = text as NSString
        return ComposeSpellLanguages.runs(in: ns, range: range ?? NSRange(location: 0, length: ns.length),
                                          languages: languages ?? enIt,
                                          identifier: FakeIdentifier())
    }

    func testEachParagraphIsCheckedInItsLanguage() {
        let text = "Ciao Marco, grazie.\n> Hello, thanks for the files.\n> More notes.\n"
        let ns = text as NSString
        let italianEnd = NSMaxRange(ns.range(of: "grazie.\n"))
        XCTAssertEqual(runs(text), [
            .init(range: NSRange(location: 0, length: italianEnd), language: "it"),
            // "More notes." cannot be told and takes the paragraph before it.
            .init(range: NSRange(location: italianEnd, length: ns.length - italianEnd),
                  language: "en"),
        ])
    }

    func testRunsCoverTheRequestedRangeExactly() {
        let text = "Ciao a tutti\nHello there\nThanks again"
        let ns = text as NSString
        let range = NSRange(location: 5, length: ns.length - 9)
        let result = runs(text, range: range)
        XCTAssertEqual(result.first?.range.location, range.location)
        XCTAssertEqual(result.map(\.range.length).reduce(0, +), range.length)
        for (a, b) in zip(result, result.dropFirst()) {
            XCTAssertEqual(NSMaxRange(a.range), b.range.location)
        }
        XCTAssertEqual(result.map(\.language), ["it", "en"])
    }

    func testAShortLineTakesItsLanguageFromTheTextAroundIt() {
        // AppKit checks the line being typed; "Marco," alone cannot be told.
        let text = "Ciao, grazie mille.\nMarco,\n"
        let ns = text as NSString
        let line = ns.range(of: "Marco,")
        XCTAssertEqual(runs(text, range: line), [.init(range: line, language: "it")])
    }

    func testUntellableTextFallsBackToTheFirstLanguage() {
        XCTAssertEqual(runs("12345\n67890", languages: ["it", "en"]).map(\.language), ["it"])
        XCTAssertEqual(runs("", range: NSRange(location: 0, length: 0)),
                       [.init(range: NSRange(location: 0, length: 0), language: "en")])
    }

    func testAnOutOfBoundsRangeIsClamped() {
        let result = runs("Hello", range: NSRange(location: 2, length: 99))
        XCTAssertEqual(result, [.init(range: NSRange(location: 2, length: 3), language: "en")])
    }

    func testAVeryLongCheckIsOneRun() {
        let paragraphs = (0..<(ComposeSpellLanguages.maxRunsPerCheck + 1))
            .map { $0 % 2 == 0 ? "Ciao" : "Hello" }
        let text = paragraphs.joined(separator: "\n")
        let result = runs(text)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.range, NSRange(location: 0, length: (text as NSString).length))
    }

    func testTheSystemRecognizerTellsItalianFromEnglish() {
        // NLLanguageRecognizer ships with macOS; no spelling dictionary is
        // involved.
        let identifier = NaturalLanguageSpellIdentifier()
        XCTAssertEqual(identifier.dominantLanguage(
            of: "Grazie per il messaggio, ti rispondo domani mattina con i dettagli della riunione.",
            among: ["en", "it"]), "it")
        XCTAssertEqual(identifier.dominantLanguage(
            of: "Thanks for the message, I will get back to you tomorrow morning with the details.",
            among: ["en_GB", "it"]), "en_GB")
        // One base language: nothing to tell apart.
        XCTAssertEqual(identifier.dominantLanguage(of: "anything", among: ["en", "en_GB"]), "en")
        XCTAssertNil(identifier.dominantLanguage(of: "anything", among: []))
    }

    // MARK: The text view

    final class RecordingView: MultilingualSpellTextView {
        var forwarded: [(range: NSRange, types: NSTextCheckingTypes, language: String?)] = []
        override func forwardCheck(in range: NSRange, types: NSTextCheckingTypes,
                                   options: [NSSpellChecker.OptionKey: Any]) {
            let orthography = options[.orthography] as? NSOrthography
            forwarded.append((range, types, orthography?.dominantLanguage))
        }
    }

    private let spellingAndGrammar = NSTextCheckingResult.CheckingType.spelling.rawValue
        | NSTextCheckingResult.CheckingType.grammar.rawValue
    private let orthography = NSTextCheckingResult.CheckingType.orthography.rawValue

    func testAutomaticForwardsTheCheckUnchanged() {
        let view = RecordingView()
        view.string = "Ciao\nHello"
        view.forwarded.removeAll()
        let types = spellingAndGrammar | orthography
        view.checkText(in: NSRange(location: 0, length: 10), types: types, options: [:])
        XCTAssertEqual(view.forwarded.count, 1)
        XCTAssertEqual(view.forwarded.first?.types, types)
        XCTAssertNil(view.forwarded.first?.language)
    }

    func testChosenLanguagesCheckEachRunWithItsOrthography() {
        let view = RecordingView()
        view.spellLanguageIdentifier = FakeIdentifier()
        view.spellLanguages = enIt
        view.string = "Ciao Marco\nHello Anna"
        view.forwarded.removeAll()
        view.checkText(in: NSRange(location: 0, length: 21),
                       types: spellingAndGrammar | orthography, options: [:])
        XCTAssertEqual(view.forwarded.map(\.language), ["it", "en"])
        XCTAssertEqual(view.forwarded.map(\.range),
                       [NSRange(location: 0, length: 11), NSRange(location: 11, length: 10)])
        // Spelling and grammar still run; AppKit does not detect another
        // orthography over the one given.
        XCTAssertTrue(view.forwarded.allSatisfy { $0.types == spellingAndGrammar })
    }

    func testChecksWithoutSpellingAreForwardedUnchanged() {
        let view = RecordingView()
        view.spellLanguages = enIt
        view.string = "Ciao"
        view.forwarded.removeAll()
        let types = NSTextCheckingResult.CheckingType.link.rawValue
        view.checkText(in: NSRange(location: 0, length: 4), types: types, options: [:])
        XCTAssertEqual(view.forwarded.count, 1)
        XCTAssertEqual(view.forwarded.first?.types, types)
        XCTAssertNil(view.forwarded.first?.language)
    }

    func testApplySetsTheLanguagesOnlyOnMultilingualViews() {
        let view = MultilingualSpellTextView()
        view.spellLanguageChecker = FakeChecker(available: ["en", "it", "de"], preferred: ["it"])
        ComposeSpellCheck.apply(.init(spelling: true, grammar: true, languages: "en,it"), to: view)
        XCTAssertEqual(view.spellLanguages, ["it", "en"])
        XCTAssertTrue(view.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)

        ComposeSpellCheck.apply(.init(spelling: true, grammar: true, languages: "nl"), to: view)
        XCTAssertNil(view.spellLanguages, "a set with nothing installed is automatic")

        ComposeSpellCheck.apply(.init(spelling: true, grammar: true, languages: ""), to: view)
        XCTAssertNil(view.spellLanguages)

        // A plain view (any other text field) is never touched.
        let plain = NSTextView()
        ComposeSpellCheck.apply(.init(spelling: true, grammar: true, languages: "en,it"), to: plain)
        XCTAssertTrue(plain.isContinuousSpellCheckingEnabled)
    }

    func testTheComposeEditorsAreMultilingual() {
        XCTAssertTrue(ComposeCaretSettlingTextView() is MultilingualSpellTextView)
    }

    // MARK: Suggestions

    func testSuggestionsComeFromTheParagraphLanguageFirst() {
        let checker = FakeChecker()
        checker.suggestions = ["en": ["fiel": ["file", "field", "feel"]],
                               "it": ["fiel": ["fiele", "file"]]]
        XCTAssertEqual(ComposeSpellLanguages.guesses(
            for: "fiel", paragraphLanguage: "it", languages: enIt,
            documentTag: 0, checker: checker),
            ["fiele", "file", "field", "feel"])
        XCTAssertEqual(ComposeSpellLanguages.guesses(
            for: "fiel", paragraphLanguage: nil, languages: enIt,
            documentTag: 0, checker: checker, limit: 2),
            ["file", "field"])
    }

    private func appKitLikeMenu(guesses: [String]) -> NSMenu {
        let menu = NSMenu()
        for guess in guesses {
            menu.addItem(withTitle: guess, action: NSSelectorFromString("_changeSpellingFromMenu:"),
                         keyEquivalent: "")
        }
        if guesses.isEmpty {
            let none = NSMenuItem(title: "No Guesses Found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Ignore Spelling",
                     action: NSSelectorFromString("_ignoreSpellingFromMenu:"), keyEquivalent: "")
        menu.addItem(withTitle: "Learn Spelling",
                     action: NSSelectorFromString("_learnSpellingFromMenu:"), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        return menu
    }

    func testTheSuggestionSectionIsFound() {
        XCTAssertEqual(ComposeSpellLanguages.spellingGuessItems(in: appKitLikeMenu(guesses: ["a", "b"])),
                       0..<2)
        XCTAssertEqual(ComposeSpellLanguages.spellingGuessItems(in: appKitLikeMenu(guesses: [])),
                       0..<1)
    }

    func testAMenuOfAnotherShapeIsLeftAlone() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        XCTAssertNil(ComposeSpellLanguages.spellingGuessItems(in: menu))
        XCTAssertNil(ComposeSpellLanguages.spellingGuessItems(in: NSMenu()))
    }

    func testRightClickSuggestionsReplaceTheWord() {
        let view = MultilingualSpellTextView()
        let checker = FakeChecker(dictionary: ["it": ["ciao", "grazie"]])
        checker.suggestions = ["it": ["grazei": ["grazie"]], "en": ["grazei": ["graze"]]]
        view.spellLanguageChecker = checker
        view.spellLanguageIdentifier = FakeIdentifier()
        view.spellLanguages = enIt
        view.string = "Ciao, grazei mille"
        let wordStart = (view.string as NSString).range(of: "grazei").location

        let menu = appKitLikeMenu(guesses: ["grace"])
        XCTAssertTrue(view.replaceSpellingGuesses(in: menu, atCharacterIndex: wordStart + 2))
        XCTAssertEqual(menu.items.prefix(2).map(\.title), ["grazie", "graze"])
        XCTAssertEqual(menu.items[2].isSeparatorItem, true)

        view.applySpellingGuess(menu.items[0])
        XCTAssertEqual(view.string, "Ciao, grazie mille")

        // A correct word keeps AppKit's menu.
        let other = appKitLikeMenu(guesses: ["x"])
        XCTAssertFalse(view.replaceSpellingGuesses(in: other, atCharacterIndex: 1))
        XCTAssertEqual(other.items.first?.title, "x")
    }

    func testAStaleSuggestionDoesNothing() {
        let view = MultilingualSpellTextView()
        view.string = "Ciao grazei"
        let item = NSMenuItem(title: "grazie", action: nil, keyEquivalent: "")
        item.representedObject = SpellingGuessChoice(
            range: NSRange(location: 5, length: 6), word: "grazei", replacement: "grazie")
        view.string = "Ciao Marco!"
        view.applySpellingGuess(item)
        XCTAssertEqual(view.string, "Ciao Marco!")
    }

    // MARK: AppKit routes continuous checking through the hook

    func testContinuousCheckingGoesThroughTheLanguageHook() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = RecordingView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView?.addSubview(view)
        view.spellLanguageIdentifier = FakeIdentifier()
        view.spellLanguageChecker = FakeChecker()
        view.spellLanguages = enIt
        view.isContinuousSpellCheckingEnabled = true
        window.makeFirstResponder(view)
        view.forwarded.removeAll()
        view.insertText("Hello there, thanks for the notes. ",
                        replacementRange: NSRange(location: NSNotFound, length: 0))
        let deadline = Date().addingTimeInterval(5)
        while view.forwarded.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(view.forwarded.isEmpty, "continuous checking bypassed checkText(in:types:options:)")
        XCTAssertEqual(view.forwarded.first?.language, "en")
        window.close()
    }
}
