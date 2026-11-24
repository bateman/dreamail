import AppKit
import NaturalLanguage

/// Which languages the compose spell checker checks against.
///
/// MishMail has no dictionaries of its own: NSSpellChecker checks on this Mac
/// with the languages macOS provides (System Settings ▸ Keyboard ▸ Text Input
/// ▸ Edit ▸ Spelling) and the user's learned words.
///
/// - Automatic, the default, stored as an empty string: MishMail sets no
///   language, so the system setting applies unchanged. With macOS's own
///   default, "Automatic by Language", the checker picks the language of
///   each paragraph among the languages in that setting's list.
/// - An explicit set (for example English and Italian) is MishMail's own and
///   changes nothing for other apps. Each paragraph is checked in the chosen
///   language it reads as, and a word is underlined only when it is
///   misspelled in every chosen language. That second rule is what keeps an
///   English sentence quoted in an Italian reply, or an Italian name in an
///   English sentence, free of red underlines; the cost is that a typo which
///   happens to be a word in another chosen language is not caught.
enum ComposeSpellLanguages {
    static let storageKey = "composeSpellCheckLanguages"

    // MARK: Persistence

    /// Stored codes, in stored order, without blanks or repeats.
    static func decode(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func encode(_ languages: [String]) -> String {
        decode(languages.joined(separator: ",")).joined(separator: ",")
    }

    /// The languages to check against, or nil for automatic. A stored
    /// language that is no longer installed is dropped; when none is left
    /// the setting falls back to automatic rather than to no checking.
    /// Order: the system's preferred spelling languages first, then the
    /// order macOS lists them in; the first one is the fallback for text
    /// whose language cannot be told.
    static func resolve(stored raw: String,
                        available: [String],
                        preferred: [String]) -> [String]? {
        let installed = Set(available)
        let chosen = decode(raw).filter(installed.contains)
        guard !chosen.isEmpty else { return nil }
        func rank(_ code: String) -> (Int, Int) {
            (preferred.firstIndex(of: code) ?? Int.max,
             available.firstIndex(of: code) ?? Int.max)
        }
        return chosen.sorted { rank($0) < rank($1) }
    }

    static func resolve(stored raw: String,
                        checker: SpellLanguageChecking) -> [String]? {
        guard !decode(raw).isEmpty else { return nil }
        return resolve(stored: raw, available: checker.availableLanguages,
                       preferred: checker.userPreferredLanguages)
    }

    /// What "Specific languages" starts from: the languages already in the
    /// system's spelling list, else the current system language, else the
    /// first installed one.
    static func defaultSelection(available: [String], preferred: [String],
                                 current: String) -> [String] {
        let installed = Set(available)
        let fromPreferred = preferred.filter(installed.contains)
        if !fromPreferred.isEmpty { return fromPreferred }
        if installed.contains(current) { return [current] }
        return available.first.map { [$0] } ?? []
    }

    /// "it" → "Italian", "en_GB" → "English (United Kingdom)", in the
    /// user's own language.
    static func displayName(for code: String, locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: code) ?? code
    }

    /// "en_GB" → "en", "pt-BR" → "pt".
    static func baseLanguage(of code: String) -> String {
        String(code.split(whereSeparator: { $0 == "_" || $0 == "-" }).first ?? Substring(code))
            .lowercased()
    }

    // MARK: Which language each paragraph is checked in

    struct CheckRun: Equatable {
        var range: NSRange
        var language: String
    }

    /// More paragraphs than this in one check (a long quoted thread loaded
    /// at once) are checked as one run, in the language most of them read as.
    static let maxRunsPerCheck = 64
    /// Characters read to tell a paragraph's language; enough for the
    /// recognizer, and bounded so a huge paragraph costs nothing extra.
    static let identificationSample = 1_000

    /// Splits a range AppKit is about to check into runs of paragraphs in one
    /// language, each to be checked in that language. Runs cover `range`
    /// exactly. A paragraph whose language cannot be told (a greeting, a
    /// signature, a line of numbers) takes its neighbour's.
    static func runs(in text: NSString, range: NSRange, languages: [String],
                     identifier: SpellLanguageIdentifying) -> [CheckRun] {
        guard let fallback = languages.first else { return [] }
        let start = min(max(range.location, 0), text.length)
        let end = min(max(NSMaxRange(range), start), text.length)
        let target = NSRange(location: start, length: end - start)

        func identify(_ r: NSRange) -> String? {
            let sample = NSRange(location: r.location,
                                 length: min(r.length, identificationSample))
            guard sample.length > 0 else { return nil }
            return identifier.dominantLanguage(of: text.substring(with: sample),
                                               among: languages)
        }
        /// The range plus one paragraph on each side, for text too short to
        /// tell on its own (a check of the one line being typed).
        func context() -> String? {
            let para = text.paragraphRange(for: target)
            let before = para.location > 0
                ? text.paragraphRange(for: NSRange(location: para.location - 1, length: 0)).location
                : para.location
            let afterEnd = NSMaxRange(para) < text.length
                ? NSMaxRange(text.paragraphRange(for: NSRange(location: NSMaxRange(para), length: 0)))
                : NSMaxRange(para)
            return identify(NSRange(location: before, length: afterEnd - before))
        }

        guard target.length > 0 else {
            return [CheckRun(range: target, language: context() ?? fallback)]
        }

        var paragraphs: [(range: NSRange, language: String?)] = []
        text.enumerateSubstrings(in: text.paragraphRange(for: target),
                                 options: [.byParagraphs, .substringNotRequired]) {
            _, contentRange, enclosingRange, _ in
            let clipped = NSIntersectionRange(enclosingRange, target)
            guard clipped.length > 0 else { return }
            paragraphs.append((clipped, identify(contentRange)))
        }
        guard !paragraphs.isEmpty else {
            return [CheckRun(range: target, language: context() ?? fallback)]
        }
        if paragraphs.count > maxRunsPerCheck {
            return [CheckRun(range: target, language: identify(target) ?? fallback)]
        }

        // Unknown paragraphs take the nearest known one before them, then
        // after them; with none known, the surrounding text decides.
        var languagesByParagraph = paragraphs.map(\.language)
        var last: String?
        for i in languagesByParagraph.indices {
            if let l = languagesByParagraph[i] { last = l } else { languagesByParagraph[i] = last }
        }
        var next: String?
        for i in languagesByParagraph.indices.reversed() {
            if let l = paragraphs[i].language { next = l }
            if languagesByParagraph[i] == nil { languagesByParagraph[i] = next }
        }
        var surrounding: String??
        var result: [CheckRun] = []
        for (i, paragraph) in paragraphs.enumerated() {
            let language: String
            if let known = languagesByParagraph[i] {
                language = known
            } else {
                if surrounding == nil { surrounding = .some(context()) }
                language = (surrounding ?? nil) ?? fallback
            }
            if let lastRun = result.last, lastRun.language == language,
               NSMaxRange(lastRun.range) == paragraph.range.location {
                result[result.count - 1].range.length += paragraph.range.length
            } else {
                result.append(CheckRun(range: paragraph.range, language: language))
            }
        }
        return result
    }

    // MARK: The "correct in any chosen language" rule

    /// Drops a spelling mark when the word is correct in any chosen
    /// language; grammar and every other result pass through untouched.
    /// `documentTag` is the text view's spell document, so words the user
    /// chose to ignore in this message stay unmarked.
    static func filter(_ results: [NSTextCheckingResult], in text: NSString,
                       languages: [String], documentTag: Int,
                       checker: SpellLanguageChecking) -> [NSTextCheckingResult] {
        guard !languages.isEmpty else { return results }
        return results.filter { result in
            guard result.resultType == .spelling else { return true }
            let r = result.range
            guard r.location != NSNotFound, r.length > 0,
                  NSMaxRange(r) <= text.length else { return true }
            let word = text.substring(with: r)
            return !languages.contains {
                checker.isCorrect(word, language: $0, documentTag: documentTag)
            }
        }
    }

    /// Suggestions for a word misspelled in every chosen language: those of
    /// the language its paragraph is written in first, then the others'.
    static func guesses(for word: String, paragraphLanguage: String?,
                        languages: [String], documentTag: Int,
                        checker: SpellLanguageChecking, limit: Int = 6) -> [String] {
        var order = languages
        if let first = paragraphLanguage, let i = order.firstIndex(of: first) {
            order.remove(at: i)
            order.insert(first, at: 0)
        }
        var seen = Set<String>([word])
        var out: [String] = []
        for language in order {
            for guess in checker.guesses(for: word, language: language,
                                         documentTag: documentTag)
            where seen.insert(guess).inserted {
                out.append(guess)
                if out.count == limit { return out }
            }
        }
        return out
    }

    /// The suggestion items at the top of NSTextView's contextual menu for a
    /// misspelled word: the items before the first separator, when the next
    /// section holds Ignore / Learn Spelling. Nil when the menu does not have
    /// that shape (not on a misspelled word, or a future AppKit layout), so
    /// the menu is then left exactly as AppKit built it.
    static func spellingGuessItems(in menu: NSMenu) -> Range<Int>? {
        let items = menu.items
        guard let separator = items.firstIndex(where: \.isSeparatorItem),
              separator > 0 else { return nil }
        func selectorName(_ item: NSMenuItem) -> String {
            item.action.map { NSStringFromSelector($0).lowercased() } ?? ""
        }
        let leading = items[..<separator]
        // Suggestions, or AppKit's disabled "No Guesses Found".
        guard leading.allSatisfy({ item in
            selectorName(item).contains("spelling") || (item.action == nil && !item.isEnabled)
        }) else { return nil }
        let nextSection = items[(separator + 1)...].prefix { !$0.isSeparatorItem }
        guard nextSection.contains(where: {
            let name = selectorName($0)
            return name.contains("ignorespelling") || name.contains("learnspelling")
        }) else { return nil }
        return 0..<separator
    }
}

// MARK: - Seams

/// The part of NSSpellChecker the language logic needs, so tests can run
/// against a fake: the runner's installed dictionaries are not the user's.
protocol SpellLanguageChecking {
    var availableLanguages: [String] { get }
    var userPreferredLanguages: [String] { get }
    var currentLanguage: String { get }
    func isCorrect(_ word: String, language: String, documentTag: Int) -> Bool
    func guesses(for word: String, language: String, documentTag: Int) -> [String]
}

/// NSSpellChecker on this Mac. Nothing leaves the device.
struct SystemSpellLanguageChecker: SpellLanguageChecking {
    var availableLanguages: [String] { NSSpellChecker.shared.availableLanguages }
    var userPreferredLanguages: [String] { NSSpellChecker.shared.userPreferredLanguages }
    var currentLanguage: String { NSSpellChecker.shared.language() }

    func isCorrect(_ word: String, language: String, documentTag: Int) -> Bool {
        let misspelled = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: language, wrap: false,
            inSpellDocumentWithTag: documentTag, wordCount: nil)
        return misspelled.location == NSNotFound
    }

    func guesses(for word: String, language: String, documentTag: Int) -> [String] {
        NSSpellChecker.shared.guesses(
            forWordRange: NSRange(location: 0, length: (word as NSString).length),
            in: word, language: language, inSpellDocumentWithTag: documentTag) ?? []
    }
}

protocol SpellLanguageIdentifying {
    /// The chosen language `text` reads as, or nil when it cannot be told.
    func dominantLanguage(of text: String, among languages: [String]) -> String?
}

/// Apple's on-device language recognizer, limited to the chosen languages.
struct NaturalLanguageSpellIdentifier: SpellLanguageIdentifying {
    /// Below this the paragraph takes a neighbour's language instead.
    var minimumConfidence = 0.6

    func dominantLanguage(of text: String, among languages: [String]) -> String? {
        guard !languages.isEmpty else { return nil }
        let bases = Array(Set(languages.map(ComposeSpellLanguages.baseLanguage(of:))))
        guard bases.count > 1 else { return languages.first }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = bases.map { NLLanguage(rawValue: $0) }
        recognizer.processString(text)
        guard let (best, confidence) = recognizer.languageHypotheses(withMaximum: 1)
                .max(by: { $0.value < $1.value }),
              confidence >= minimumConfidence else { return nil }
        return languages.first { ComposeSpellLanguages.baseLanguage(of: $0) == best.rawValue }
    }
}
