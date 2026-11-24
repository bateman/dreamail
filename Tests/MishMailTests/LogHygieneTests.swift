import XCTest
import GRDB

/// F-03 outside `DiagnosticLog`: what reaches the unified log (readable by
/// other tools, collected by sysdiagnose) is an error's category, never its
/// description, which can carry SQL text, file paths or message text; and
/// the opt-in perf lines carry counts, never a message, thread or account id.
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
        let path = "/Users/alice/Library/Containers/io.github.bateman.MishMail/Data/mcp.json"
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
            domain, code), mark free text .private, and keep ids out of perf meta.
            """)
    }

    /// The text-layout exception reason can quote the text being laid out
    /// (message content): it stays in the log for local debugging, private.
    func testTextLayoutExceptionReasonIsLoggedOnlyPrivately() throws {
        let source = try String(contentsOf: Self.repoRoot
            .appendingPathComponent("Sources/MishMail/Support/SafeTextLayout.m"), encoding: .utf8)
        let reasons = LogScan.loggedValues(in: Array(source), objC: true)
            .filter { $0.expression.contains("reason") }
        XCTAssertFalse(reasons.isEmpty, "the exception reason should still be logged")
        XCTAssertTrue(reasons.allSatisfy { !$0.isPublic }, "\(reasons)")
    }

    // MARK: - What the guard rejects and accepts

    func testScannerRejectsTheRemovedForms() {
        let swift = [
            #"NSLog("MishMail: vacuum failed: %@", "\(error)")"#,
            #"NSLog("MishMail: %@", error.localizedDescription)"#,
            #"NSLog("MishMail: failed \(error)")"#,
            #"logger.error("sync failed: \(error, privacy: .public)")"#,
            #"logger.error("\(err.localizedDescription, privacy: .public)")"#,
            #"PerfMetrics.begin(.openReady, meta: "thread=\(thread.id) preseeded=\(preseeded)")"#,
            #"interval.end(extraMeta: "account=\(accountId)")"#,
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
            #"NSLog("MishMail: vacuum failed: %@", DiagnosticLog.describe(error))"#,
            #"NSLog("MishMail: plaintext cache busy; encryption deferred")"#,
            #"NSLog("MishMail: opened read-only (%@)", "\(storageState)")"#,
            #"NSLog("MishMail AI %@: %@", task.rawValue, notice)"#,
            #"logger.error("\(message, privacy: .public)")"#,
            #"logger.error("\(error, privacy: .private)")"#,
            #"logger.error("open failed: errno \(errno, privacy: .public)")"#,
            #"PerfMetrics.measure(.navDetailOpen, meta: id == nil ? "close" : "open") { () }"#,
            #"PerfMetrics.begin(.openReady, meta: "preseeded=\(preseeded) n=\(ids.count)")"#,
            #"PerfMetrics.measure(.syncGetRetry, meta: "skipped \(DiagnosticLog.describe(error))") { () }"#,
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

    /// …/Tests/MishMailTests/ThisFile.swift → repo root.
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

/// A small lexer over log call sites. It knows string literals (with Swift
/// interpolations), parentheses and commas: enough to find what each call
/// logs and whether that value is public, without a Swift parser.
enum LogScan {
    struct Value: CustomStringConvertible {
        let line: Int
        let call: String
        let expression: String
        let isPublic: Bool
        var description: String { "\(line) \(call) \(expression) public=\(isPublic)" }
    }

    /// `NSLog` writes every argument publicly; `os_log` per format specifier.
    static let swiftCalls: Set<String> = ["NSLog", "os_log"]
    static let objCCalls: Set<String> = [
        "NSLog", "os_log", "os_log_info", "os_log_debug", "os_log_error", "os_log_fault",
        "os_log_with_type",
    ]
    /// PerfMetrics writes its meta publicly when the opt-in flag is on.
    static let perfCalls: Set<String> = [
        "PerfMetrics.begin", "PerfMetrics.measure", "PerfMetrics.measureAsync",
    ]

    static func findings(in source: String, objC: Bool) -> [String] {
        let c = Array(source)
        var out: [String] = []
        for value in loggedValues(in: c, objC: objC) where value.isPublic {
            for e in exposed(value.expression) where isErrorText(e) {
                out.append("\(value.line): \(value.call) logs `\(trim(e))` publicly")
            }
        }
        guard !objC else { return out }
        for (line, e) in publicInterpolations(c) {
            for part in exposed(e) where isErrorText(part) {
                out.append("\(line): `\(trim(part))` interpolated with privacy: .public")
            }
        }
        for (line, call, e) in perfMetaInterpolations(c) where isErrorText(e) || isIdentifier(e) {
            out.append("\(line): \(call) meta carries `\(trim(e))`")
        }
        return out
    }

    /// Every value a log call passes, with whether it lands in the log publicly.
    static func loggedValues(in c: [Character], objC: Bool) -> [Value] {
        let names = objC ? objCCalls : swiftCalls
        var out: [Value] = []
        for (name, open) in calls(in: c, where: { names.contains($0) }) {
            guard let close = closingParen(c, open: open) else { continue }
            let line = lineNumber(c, at: open)
            var args = splitTopLevel(Array(c[(open + 1)..<close]))
            if !objC {
                args = args.filter { arg in
                    !["log:", "type:", "dso:"].contains { arg.hasPrefix($0) }
                }
            }
            let formatIndex: Int
            if !objC || name == "NSLog" {
                formatIndex = 0
            } else if name == "os_log_with_type" {
                formatIndex = 2
            } else {
                formatIndex = 1
            }
            guard args.count > formatIndex else { continue }
            let format = args[formatIndex]
            // Swift interpolations in an NSLog format are public too.
            out.append(Value(line: line, call: name, expression: format, isPublic: name == "NSLog"))
            let specifiers = formatSpecifiers(format)
            for (k, arg) in args.dropFirst(formatIndex + 1).enumerated() {
                let spec = k < specifiers.count ? specifiers[k] : ""
                let defaultPrivate = spec.hasSuffix("@") || spec.hasSuffix("s")
                let isPublic = name == "NSLog"
                    || (!spec.contains("{private}") && (spec.contains("{public}") || !defaultPrivate))
                out.append(Value(line: line, call: name, expression: arg, isPublic: isPublic))
            }
        }
        return out
    }

    /// `\(expr, privacy: .public)` anywhere in a Swift file: Logger lines.
    static func publicInterpolations(_ c: [Character]) -> [(Int, String)] {
        var out: [(Int, String)] = []
        var i = 0
        while i + 1 < c.count {
            if c[i] == "\\", c[i + 1] == "(", let close = closingParen(c, open: i + 1) {
                let parts = splitTopLevel(Array(c[(i + 2)..<close]))
                let isPublic = parts.dropFirst().contains {
                    $0.replacingOccurrences(of: " ", with: "").hasPrefix("privacy:.public")
                }
                if parts.count > 1, isPublic { out.append((lineNumber(c, at: i), parts[0])) }
            }
            i += 1
        }
        return out
    }

    /// Interpolations in the meta of `PerfMetrics.begin/measure/measureAsync`
    /// and of `Interval.end(extraMeta:)`.
    static func perfMetaInterpolations(_ c: [Character]) -> [(Int, String, String)] {
        var out: [(Int, String, String)] = []
        for (name, open) in calls(in: c, where: { perfCalls.contains($0) || $0.hasSuffix(".end") }) {
            guard let close = closingParen(c, open: open) else { continue }
            let body = Array(c[(open + 1)..<close])
            if name.hasSuffix(".end"),
               !String(body).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("extraMeta:") {
                continue
            }
            let line = lineNumber(c, at: open)
            for arg in splitTopLevel(body) {
                for e in exposed(arg).dropFirst() { out.append((line, name, e)) }
            }
        }
        return out
    }

    // MARK: Classification

    /// An error's description or a raw exception reason, unless it is
    /// already reduced to its category by `DiagnosticLog.describe`.
    static func isErrorText(_ expression: String) -> Bool {
        let e = trim(expression)
        if e.hasPrefix("DiagnosticLog.describe(") { return false }
        let pattern = #"\b(error|err|exception)\b(?!\.name\b)|localizedDescription|\.reason\b|userInfo|debugDescription"#
        return e.range(of: pattern, options: .regularExpression) != nil
    }

    /// A message, thread, label or account id, or another identifying field.
    static func isIdentifier(_ expression: String) -> Bool {
        let e = trim(expression)
        if e.hasSuffix(".count") || e.hasSuffix(".isEmpty") { return false }
        let pattern = #"(^|[^A-Za-z0-9_])ids?\b|[a-z](Id|ID)s?\b|(?i:email|address|subject|snippet|token)"#
        return e.range(of: pattern, options: .regularExpression) != nil
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

    /// Index of the `)` closing the `(` at `open`; string literals skipped.
    static func closingParen(_ c: [Character], open: Int) -> Int? {
        var depth = 0
        var i = open
        while i < c.count {
            switch c[i] {
            case "\"":
                guard let end = endOfString(c, from: i) else { return nil }
                i = end
                continue
            case "(":
                depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return i }
            default:
                break
            }
            i += 1
        }
        return nil
    }

    /// Index just past the literal opened by the `"` at `start`.
    static func endOfString(_ c: [Character], from start: Int) -> Int? {
        if start + 2 < c.count, c[start + 1] == "\"", c[start + 2] == "\"" {
            var i = start + 3
            while i + 2 < c.count {
                if c[i] == "\\" { i += 2; continue }
                if c[i] == "\"", c[i + 1] == "\"", c[i + 2] == "\"" { return i + 3 }
                i += 1
            }
            return nil
        }
        var i = start + 1
        while i < c.count {
            switch c[i] {
            case "\\":
                if i + 1 < c.count, c[i + 1] == "(" {
                    guard let close = closingParen(c, open: i + 1) else { return nil }
                    i = close + 1
                } else {
                    i += 2
                }
            case "\"":
                return i + 1
            case "\n":
                return nil
            default:
                i += 1
            }
        }
        return nil
    }

    /// Arguments at depth 0, trimmed.
    static func splitTopLevel(_ c: [Character]) -> [String] {
        var parts: [String] = []
        var start = 0
        var depth = 0
        var i = 0
        while i < c.count {
            switch c[i] {
            case "\"":
                i = endOfString(c, from: i) ?? c.count
                continue
            case "(", "[", "{":
                depth += 1
            case ")", "]", "}":
                depth -= 1
            case "," where depth == 0:
                parts.append(String(c[start..<i]))
                start = i + 1
            default:
                break
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
        var interpolations: [String] = []
        var i = 0
        while i < c.count {
            guard c[i] == "\"" else {
                code.append(c[i])
                i += 1
                continue
            }
            let end = endOfString(c, from: i) ?? c.count
            var j = i + 1
            while j < end {
                if c[j] == "\\" {
                    if j + 1 < end, c[j + 1] == "(", let close = closingParen(c, open: j + 1) {
                        interpolations.append(String(c[(j + 2)..<close]))
                        j = close + 1
                    } else {
                        j += 2
                    }
                } else {
                    j += 1
                }
            }
            code += "\"\""
            i = end
        }
        return [code] + interpolations
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
