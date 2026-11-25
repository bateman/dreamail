import XCTest

/// The product was renamed from MishMail to DreaMail (DEC-065). The old name
/// must not come back in the tracked product tree: code, tests, scripts, CI,
/// configuration, design files, build files and the top-level README,
/// CONTRIBUTING and SECURITY. docs/, CHANGELOG.md and CLAUDE.md are out of
/// reach of a unit test (see below).
///
/// Every old form counts: the name in any case (`MishMail`, `mishmail`,
/// `MISHMAIL_…`), "Mish" as a word or identifier part (`Ask Mish`,
/// `AskMish…`, `askMish…`) and the palette id `askmish`. References to the
/// upstream project, which keeps the name, are removed before matching. The
/// few lines that must still name the old product are listed in `allowed`,
/// each with its reason; an entry that no longer matches fails too, so the
/// list cannot go stale. The scan walks the files on disk, not
/// `git ls-files`, so an untracked file in a local checkout is scanned too.
final class OldProductNameTests: XCTestCase {

    /// Built in pieces so the forms never appear whole in this file.
    private static let mish = "Mi" + "sh"
    private static let name = mish + "Mail"

    private static let patterns: [NSRegularExpression] = [
        // The name in any case, also inside identifiers and paths.
        try! NSRegularExpression(pattern: name, options: [.caseInsensitive]),
        // "Mish" as a word or identifier part, not an English word ("Mishap").
        try! NSRegularExpression(pattern: "\(mish)(?![a-z])"),
        // The lower-case palette id.
        try! NSRegularExpression(pattern: "ask[ _-]?\(mish)", options: [.caseInsensitive]),
    ]

    /// The upstream project's own identifiers: another product, still named so.
    private static let upstreamForms = [
        "ronboger/" + name.lowercased(),
        "dev." + "ronboger." + name,
    ]

    /// Files outside the scan, with the reason.
    private static let skippedFiles: Set<String> = [
        // This guard: its allow-list spells the lines it allows.
        "Tests/DreaMailTests/OldProductNameTests.swift",
    ]

    /// Lines that must still carry the old name, by file. Each is matched
    /// against the trimmed line.
    private static let allowed: [String: Set<String>] = [
        // Credit to the project DreaMail derives from (MIT, study section 7).
        "Sources/DreaMail/App/DreaMailApp.swift": [
            "+ \"Based on \(name) by Ron Boger.\",",
        ],
        "README.md": [
            // Upstream binaries and the credit in the licence section.
            "builds of the upstream project, \(name), are on",
            "[\(name)](https://github.com/ronboger/\(name.lowercased())) by Ron Boger. Depends on",
            // How to remove what a pre-rename install left behind.
            "### Coming from a \(name) install of this fork",
            "Until November 2026 this fork was called \(name), with bundle identifier",
            "`io.github.bateman.\(name)` (Debug: `io.github.bateman.\(name).debug`).",
            "works, quit \(name) and remove what it left behind:",
            "rm -rf /Applications/\(name).app",
            "rm -rf ~/Library/Containers/io.github.bateman.\(name) ~/Library/Containers/io.github.bateman.\(name).debug",
            "rm -f ~/Library/Logs/\(name)Relauncher.log /tmp/\(name.lowercased())-summarize.log /tmp/\(name.lowercased())-summarize.err",
            "rm -rf ~/.config/\(name.lowercased())",
            "client, so removing \(name)'s Keychain items is enough; to end the grant",
            "security delete-generic-password -s io.github.bateman.\(name)",
            "security delete-generic-password -s io.github.bateman.\(name).debug",
            "security delete-generic-password -s io.github.bateman.\(name).openpgp",
            "security delete-generic-password -s io.github.bateman.\(name).debug.openpgp",
            "`launchctl bootout gui/$(id -u)/io.github.bateman.\(name.lowercased())-summarize` and",
            "delete `~/Library/LaunchAgents/io.github.bateman.\(name.lowercased())-summarize.plist`.",
            "A `Config/Local.xcconfig` that still sets `\(name.uppercased())_…` switches is ignored:",
            "notarization profile stored as `\(name)-notary` must be stored again as",
            "rm -rf \(name).xcodeproj ~/Library/Developer/Xcode/DerivedData/\(name)-*",
        ],
    ]

    static func namesOldProduct(_ text: String) -> Bool {
        var text = text
        for form in upstreamForms { text = text.replacingOccurrences(of: form, with: "") }
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    // MARK: - The matcher

    func testMatcherCatchesEachOldForm() {
        let n = Self.name, m = Self.mish
        for text in [n, n.lowercased(), n.uppercased() + "_DEMO", "Sources/\(n)/App",
                     "Ask \(m)", "Ask\(m)Controller", "ask\(m)Visible", "Handle with \(m)",
                     "handleSelectedThreadWith\(m)", "\"ask\(m.lowercased())\"",
                     "lib\(n.lowercased())_rpgp.a"] {
            XCTAssertTrue(Self.namesOldProduct(text), text)
        }
    }

    func testMatcherIgnoresEnglishWordsAndTheUpstreamProject() {
        for text in ["a mishap", "Mishandled input", "DreaMail", "Ask AI",
                     "/* \(Self.mish.lowercased()) */",
                     "https://github.com/\(Self.upstreamForms[0])",
                     "`\(Self.upstreamForms[1]).debug`"] {
            XCTAssertFalse(Self.namesOldProduct(text), text)
        }
    }

    // MARK: - The tree

    func testOldNameIsNotUsedInTheProductTree() throws {
        let root = ForkIdentityTests.repoRoot
        var files: [String] = []
        for dir in ["Sources", "Tests", "scripts", ".github", "Config", "Design", ".oss-scanner"] {
            let base = root.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.isRegularFileKey]) else {
                XCTFail("\(dir)/ not found under \(root.path)")
                continue
            }
            for case let url as URL in walker {
                let rel = String(url.path.dropFirst(root.path.count + 1))
                if Self.namesOldProduct(url.lastPathComponent) {
                    XCTFail("old name in a path: \(rel)")
                }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                files.append(rel)
            }
        }
        // Not docs/, CHANGELOG.md or CLAUDE.md: CI skips the build when only
        // those change (.github/scripts/needs-build.py), so no unit test may
        // read them. The PR that renamed the product checked them with git grep.
        files += ["Makefile", "project.yml", "README.md", "CONTRIBUTING.md", "SECURITY.md",
                  ".gitignore"]

        var offenders: [String] = []
        var unused = Self.allowed
        for rel in files where !Self.skippedFiles.contains(rel) {
            let url = root.appendingPathComponent(rel)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated()
            where Self.namesOldProduct(line) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if Self.allowed[rel]?.contains(trimmed) == true {
                    unused[rel]?.remove(trimmed)
                } else {
                    offenders.append("\(rel):\(index + 1): \(trimmed)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "old product name used again")
        XCTAssertEqual(unused.filter { !$0.value.isEmpty }, [:],
                       "allow-list entries that no longer match: remove them")
    }

    /// The scan must actually see the tree, or an empty result proves nothing.
    func testScanReachesTheSources() throws {
        let app = try ForkIdentityTests.repoFile("Sources/DreaMail/App/DreaMailApp.swift")
        XCTAssertTrue(app.contains("struct DreaMailApp: App"))
        XCTAssertTrue(Self.namesOldProduct(app), "the About credit is no longer seen")
    }
}
