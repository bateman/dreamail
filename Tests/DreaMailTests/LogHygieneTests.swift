import XCTest
import GRDB

/// F-03 outside `DiagnosticLog`: what reaches the unified log (readable by
/// other tools, collected by sysdiagnose) is an error's category, never its
/// description, which can carry SQL text, file paths or message text; and no
/// public line carries a message, thread or account id.
///
/// The guard below is a lexical tripwire for the forms removed in step 2D,
/// not a parser. It checks the arguments of `NSLog` (Swift and Objective-C)
/// and `os_log_error` (Objective-C), `\(…, privacy: .public)` interpolations,
/// PerfMetrics `meta:` / `extraMeta:` interpolations, and `try!` on a database
/// or file open (a failed `try!` dumps the error into the crash report). It
/// does not follow a value through a variable, a helper or a wrapper (e.g.
/// `advanceForRemoval(…, extraMeta:)` in MailStore+Mutations.swift), nor `\#(…)`
/// in raw strings; comment lines are ignored. A call it cannot lex is a
/// finding, so a desynced lexer fails the test instead of passing silently.
final class LogHygieneTests: XCTestCase {

    // MARK: - The formatter the log sites reuse

    func testDatabaseErrorKeepsTheCodeButNotTheSQLOrThePath() {
        let error = DatabaseError(
            resultCode: .SQLITE_CANTOPEN,
            message: "unable to open database file /Users/alice/Library/Containers/mail.sqlite",
            sql: "ATTACH DATABASE '/Users/alice/Library/rawkeyed.sqlite' AS rawkeyed KEY ?",
            arguments: ["x'00ff00ff'"])
        // GRDB's own description is what the old `"\(error)"` logged.
        XCTAssertTrue("\(error)".contains("ATTACH DATABASE"))
        XCTAssertTrue("\(error)".contains("/Users/alice"))

        let text = DiagnosticLog.describe(error)
        for leak in ["ATTACH", "rawkeyed", "/Users", "alice", "sqlite", "00ff"] {
            XCTAssertFalse(text.contains(leak), "\(leak) in \(text)")
        }
        XCTAssertTrue(text.hasPrefix("error=DatabaseError "), text)
        XCTAssertTrue(text.contains("code=\(ResultCode.SQLITE_CANTOPEN.rawValue)"), text)
    }

    func testFileErrorKeepsDomainAndCodeButNotThePath() {
        let path = "/Users/alice/Library/Containers/io.github.bateman.DreaMail/Data/mcp.json"
        let error = CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
        XCTAssertTrue("\(error)".contains("alice"))

        let text = DiagnosticLog.describe(error)
        XCTAssertFalse(text.contains("alice"), text)
        XCTAssertFalse(text.contains("mcp.json"), text)
        XCTAssertTrue(text.contains("domain=NSCocoaErrorDomain"), text)
        XCTAssertTrue(text.contains("code=\(CocoaError.fileWriteNoPermission.rawValue)"), text)
    }

    // MARK: - Regression guard over Sources/

    func testNoLogCallExposesAnErrorDescriptionOrAnIdentifier() throws {
        var findings: [String] = []
        for url in try Self.sourceFiles() {
            let text = try String(contentsOf: url, encoding: .utf8)
            let rel = String(url.path.dropFirst(Self.repoRoot.path.count + 1))
            findings += LogScan.findings(in: text, objC: url.pathExtension == "m")
                .map { "\(rel):\($0)" }
        }
        XCTAssertEqual(findings, [], """
            Log the error's category with DiagnosticLog.describe(error) (type, \
            domain, code), mark free text .private, and keep ids out of public lines.
            """)
    }

    /// The text-layout exception reason can quote the text being laid out
    /// (message content): logged with `%{private}`, so it reads `<private>`
    /// in sysdiagnose and Console unless private data is enabled.
    func testTextLayoutExceptionReasonIsLoggedOnlyPrivately() throws {
        let source = try String(contentsOf: Self.repoRoot
            .appendingPathComponent("Sources/DreaMail/Support/SafeTextLayout.m"), encoding: .utf8)
        let reasons = LogScan.loggedValues(in: Array(source), objC: true).values
            .filter { $0.expression.contains("reason") }
        XCTAssertFalse(reasons.isEmpty, "the exception reason should still be logged")
        XCTAssertTrue(reasons.allSatisfy { !$0.isPublic }, "\(reasons)")
    }

    // MARK: - What the guard rejects and accepts

    func testScannerRejectsTheRemovedForms() {
        let swift = [
            #"NSLog("DreaMail: vacuum failed: %@", "\(error)")"#,
            #"NSLog("DreaMail: %@", error.localizedDescription)"#,
            #"NSLog("DreaMail: failed \(error)")"#,
            #"NSLog("DreaMail: opened %@", thread.id)"#,
            #"NSLog("DreaMail: %@", message.subject)"#,
            #"logger.error("sync failed: \(error, privacy: .public)")"#,
            #"logger.error("\(err.localizedDescription, privacy: .public)")"#,
            #"PerfMetrics.begin(.openReady, meta: "thread=\(thread.id) preseeded=\(preseeded)")"#,
            #"interval.end(extraMeta: "account=\(accountId)")"#,
            #"static let shared = try! AppDatabase()"#,
            // Unlexable: reported, not skipped.
            #"NSLog("DreaMail: unterminated"#,
        ]
        for snippet in swift {
            XCTAssertFalse(LogScan.findings(in: snippet, objC: false).isEmpty, snippet)
        }
        let objC = [
            #"os_log_error(OS_LOG_DEFAULT, "raised %{public}@: %{public}@", exception.name, exception.reason);"#,
            #"NSLog(@"failed: %@", error);"#,
        ]
        for snippet in objC {
            XCTAssertFalse(LogScan.findings(in: snippet, objC: true).isEmpty, snippet)
        }
    }

    func testScannerAcceptsTheRedactedForms() {
        let swift = [
            #"NSLog("DreaMail: vacuum failed: %@", DiagnosticLog.describe(error))"#,
            #"NSLog("DreaMail: plaintext cache busy; encryption deferred")"#,
            #"NSLog("DreaMail: opened read-only (%@)", "\(storageState)")"#,
            #"NSLog("DreaMail AI %@: %@", task.rawValue, notice)"#,
            #"NSLog("DreaMail: failed (code %ld)", (error as NSError).code)"#,
            ##"NSLog("DreaMail: %@", #"raw "quoted" \(error) text"#)"##,
            #"// NSLog("DreaMail: %@", "\(error)")"#,
            #"logger.error("\(message, privacy: .public)")"#,
            #"logger.error("\(error, privacy: .private)")"#,
            #"logger.error("open failed: errno \(errno, privacy: .public)")"#,
            #"PerfMetrics.measure(.navDetailOpen, meta: id == nil ? "close" : "open") { () }"#,
            #"PerfMetrics.begin(.openReady, meta: "preseeded=\(preseeded) n=\(ids.count)")"#,
            #"PerfMetrics.measure(.x, meta: "n=\(validIds.count - 1)") { () }"#,
            #"PerfMetrics.begin(.x, meta: "tokens=\(usage.outputTokens)")"#,
            #"PerfMetrics.measure(.syncGetRetry, meta: "skipped \(DiagnosticLog.describe(error))") { () }"#,
            ##"private static let re = try! NSRegularExpression(pattern: #"\d+"#)"##,
            #"lastError = error.localizedDescription"#,
        ]
        for snippet in swift {
            XCTAssertEqual(LogScan.findings(in: snippet, objC: false), [], snippet)
        }
        let objC = [
            #"os_log_error(OS_LOG_DEFAULT, "raised %{public}@: %{private}@", exception.name, exception.reason);"#,
        ]
        for snippet in objC {
            XCTAssertEqual(LogScan.findings(in: snippet, objC: true), [], snippet)
        }
    }

    // MARK: - Helpers

    /// …/Tests/DreaMailTests/ThisFile.swift → repo root.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func sourceFiles() throws -> [URL] {
        let base = repoRoot.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where ["swift", "m"].contains(url.pathExtension) {
            files.append(url)
        }
        XCTAssertGreaterThan(files.count, 50, "Sources/ not found")
        return files.sorted { $0.path < $1.path }
    }
}

/// The lexer behind the guard: string literals (with interpolations and raw
/// strings), parentheses and commas, enough to see what each call logs.
enum LogScan {
    typealias Value = (line: Int, call: String, expression: String, isPublic: Bool)

    /// Files without any of these are not lexed.
    static let markers = ["NSLog", "os_log", "privacy:", "PerfMetrics", "extraMeta", "try!"]
    static let perfCalls: Set<String> = [
        "PerfMetrics.begin", "PerfMetrics.measure", "PerfMetrics.measureAsync",
    ]

    static func findings(in source: String, objC: Bool) -> [String] {
        guard markers.contains(where: { source.contains($0) }) else { return [] }
        let lines = source.components(separatedBy: "\n").map { line -> String in
            let t = trim(line)
            return t.hasPrefix("//") || t.hasPrefix("/*") || t.hasPrefix("*") ? "" : line
        }
        let c = Array(lines.joined(separator: "\n"))
        var out: [String] = []
        let logged = loggedValues(in: c, objC: objC)
        out += logged.unparsed.map { "\($0): log call the guard cannot lex" }
        for value in logged.values where value.isPublic {
            for e in exposed(value.expression) where isErrorText(e) || isIdentifier(e) {
                out.append("\(value.line): \(value.call) logs `\(trim(e))` publicly")
            }
        }
        guard !objC else { return out }

        for (n, line) in lines.enumerated() where line.contains("privacy: .public") {
            let l = Array(line)
            var sawPublic = false
            for (start, close) in interpolations(in: l) {
                let parts = splitTopLevel(Array(l[(start + 2)..<close]))
                guard parts.dropFirst().contains(where: {
                    $0.replacingOccurrences(of: " ", with: "").hasPrefix("privacy:.public")
                }) else { continue }
                sawPublic = true
                for e in exposed(parts[0]) where isErrorText(e) || isIdentifier(e) {
                    out.append("\(n + 1): `\(trim(e))` interpolated with privacy: .public")
                }
            }
            if !sawPublic { out.append("\(n + 1): privacy: .public the guard cannot lex") }
        }

        for (name, open) in calls(in: c, where: { perfCalls.contains($0) || $0.hasSuffix(".end") }) {
            if name.hasSuffix(".end"),
               !trim(String(c[(open + 1)..<min(c.count, open + 40)])).hasPrefix("extraMeta:") { continue }
            guard let close = closingParen(c, open: open) else {
                out.append("\(lineNumber(c, at: open)): \(name) call the guard cannot lex")
                continue
            }
            for arg in splitTopLevel(Array(c[(open + 1)..<close])) {
                for e in exposed(arg).dropFirst() where isErrorText(e) || isIdentifier(e) {
                    out.append("\(lineNumber(c, at: open)): \(name) meta carries `\(trim(e))`")
                }
            }
        }

        let text = String(c)
        let tryOpen = #"try!\s*(AppDatabase|DatabasePool|DatabaseQueue|Data\(contentsOf|String\(contentsOf|FileManager)"#
        var searchStart = text.startIndex
        while let r = text.range(of: tryOpen, options: .regularExpression,
                                 range: searchStart..<text.endIndex) {
            let line = text[..<r.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            out.append("\(line): `try!` on an open would dump its error into the crash report")
            searchStart = r.upperBound
        }
        return out
    }

    /// Every value a `NSLog` / `os_log_error` call passes, with whether it
    /// lands in the log publicly; and the lines of calls that would not lex.
    static func loggedValues(in c: [Character], objC: Bool) -> (values: [Value], unparsed: [Int]) {
        let names: Set<String> = objC ? ["NSLog", "os_log_error"] : ["NSLog"]
        var values: [Value] = []
        var unparsed: [Int] = []
        for (name, open) in calls(in: c, where: { names.contains($0) }) {
            let line = lineNumber(c, at: open)
            let formatIndex = name == "NSLog" ? 0 : 1
            guard let close = closingParen(c, open: open) else { unparsed.append(line); continue }
            let args = splitTopLevel(Array(c[(open + 1)..<close]))
            guard args.count > formatIndex else { unparsed.append(line); continue }
            // NSLog writes everything publicly, Swift interpolations in its
            // format included; os_log keeps `%@` private unless `{public}`.
            let format = args[formatIndex]
            values.append((line, name, format, name == "NSLog"))
            let specifiers = formatSpecifiers(format)
            for (k, arg) in args.dropFirst(formatIndex + 1).enumerated() {
                let spec = k < specifiers.count ? specifiers[k] : ""
                let isPublic = name == "NSLog" || spec.contains("{public}")
                    || !(spec.hasSuffix("@") || spec.contains("{private}"))
                values.append((line, name, arg, isPublic))
            }
        }
        return (values, unparsed)
    }

    // MARK: Classification

    /// An error's description or a raw exception reason, unless reduced to
    /// its category (`DiagnosticLog.describe`, `(error as NSError).code`).
    static func isErrorText(_ expression: String) -> Bool {
        let e = trim(expression)
        if e.hasPrefix("DiagnosticLog.describe(") { return false }
        let rest = e.replacingOccurrences(of: #"\((error|err) as NSError\)\.(code|domain)"#,
                                          with: "", options: .regularExpression)
        let pattern = #"\b(error|err|exception)\b(?!\.name\b)|localizedDescription|\.reason\b|userInfo|debugDescription"#
        return rest.range(of: pattern, options: .regularExpression) != nil
    }

    /// A message, thread, label or account id, or another identifying field;
    /// counts of them (`ids.count`) are fine.
    static func isIdentifier(_ expression: String) -> Bool {
        let rest = trim(expression).replacingOccurrences(
            of: #"[A-Za-z_][A-Za-z0-9_.]*\.(count|isEmpty)\b"#, with: "", options: .regularExpression)
        let pattern = #"(^|[^A-Za-z0-9_])ids?\b|[a-z](Id|ID)s?\b|(?i:email|address|subject|snippet)|\b(token|accessToken|refreshToken)\b"#
        return rest.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: Lexing

    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func isIdentChar(_ ch: Character) -> Bool { ch == "_" || ch.isLetter || ch.isNumber }

    /// Dotted names immediately followed by `(`, with the index of that `(`.
    static func calls(in c: [Character], where matches: (String) -> Bool) -> [(String, Int)] {
        var out: [(String, Int)] = []
        var i = 0
        while i < c.count {
            guard isIdentChar(c[i]), i == 0 || !(isIdentChar(c[i - 1]) || c[i - 1] == ".") else {
                i += 1
                continue
            }
            var j = i
            while j < c.count, isIdentChar(c[j]) || c[j] == "." { j += 1 }
            if j < c.count, c[j] == "(", matches(String(c[i..<j])) { out.append((String(c[i..<j]), j)) }
            i = j
        }
        return out
    }

    /// `(start of \(, index of its closing paren)` for each interpolation.
    static func interpolations(in c: [Character]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var i = 0
        while i + 1 < c.count {
            if c[i] == "\\", c[i + 1] == "(", let close = closingParen(c, open: i + 1) {
                out.append((i, close))
            }
            i += 1
        }
        return out
    }

    /// Index of the `)` closing the `(` at `open`; string literals skipped.
    static func closingParen(_ c: [Character], open: Int) -> Int? {
        var depth = 0
        var i = open
        while i < c.count {
            if c[i] == "\"" {
                guard let end = endOfString(c, from: i) else { return nil }
                i = end
                continue
            }
            if c[i] == "(" { depth += 1 }
            if c[i] == ")" { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return nil
    }

    static func isRaw(_ c: [Character], _ quote: Int) -> Bool { quote > 0 && c[quote - 1] == "#" }

    /// Index just past the literal opened by the `"` at `start`. A
    /// multi-line `"""` literal does not lex: its call is reported.
    static func endOfString(_ c: [Character], from start: Int) -> Int? {
        var i = start + 1
        if isRaw(c, start) {  // #"…"#: no escapes, no `\(`
            while i + 1 < c.count, !(c[i] == "\"" && c[i + 1] == "#") { i += 1 }
            return i + 1 < c.count ? i + 2 : nil
        }
        while i < c.count, c[i] != "\"", c[i] != "\n" {
            if c[i] == "\\", i + 1 < c.count, c[i + 1] == "(" {
                guard let close = closingParen(c, open: i + 1) else { return nil }
                i = close + 1
            } else {
                i += c[i] == "\\" ? 2 : 1
            }
        }
        return i < c.count && c[i] == "\"" ? i + 1 : nil
    }

    /// Arguments at depth 0, trimmed.
    static func splitTopLevel(_ c: [Character]) -> [String] {
        var parts: [String] = []
        var start = 0
        var depth = 0
        var i = 0
        while i < c.count {
            if c[i] == "\"" {
                i = endOfString(c, from: i) ?? c.count
                continue
            }
            if "([{".contains(c[i]) { depth += 1 }
            if ")]}".contains(c[i]) { depth -= 1 }
            if c[i] == ",", depth == 0 {
                parts.append(String(c[start..<i]))
                start = i + 1
            }
            i += 1
        }
        parts.append(String(c[min(start, c.count)..<c.count]))
        return parts.map { trim($0) }.filter { !$0.isEmpty }
    }

    /// What an argument puts in the line: its code with literal text
    /// blanked (first), then the body of each interpolation.
    static func exposed(_ text: String) -> [String] {
        let c = Array(text)
        var code = ""
        var bodies: [String] = []
        var i = 0
        while i < c.count {
            guard c[i] == "\"" else {
                code.append(c[i])
                i += 1
                continue
            }
            let end = endOfString(c, from: i) ?? c.count
            if !isRaw(c, i) {
                bodies += interpolations(in: Array(c[i..<end])).map { pair in
                    String(c[(i + pair.0 + 2)..<(i + pair.1)])
                }
            }
            code += "\"\""
            i = end
        }
        return [code] + bodies
    }

    /// `%@`, `%{public}@`, `%d`… in order; `%%` skipped.
    static func formatSpecifiers(_ format: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"%(%|(\{[^}]*\})?[-+ #0-9.*]*[hlqLztj]*[@a-zA-Z])"#) else { return [] }
        let range = NSRange(format.startIndex..., in: format)
        return regex.matches(in: format, range: range).compactMap { match in
            Range(match.range, in: format).map { String(format[$0]) }
        }.filter { $0 != "%%" }
    }

    static func lineNumber(_ c: [Character], at index: Int) -> Int {
        c[..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }
}
