import XCTest

/// MishMail no longer carries a migration path from, or a style borrowed by
/// name from, another mail product. Its name must not come back in the
/// tracked product tree: code, tests, scripts, CI, configuration, design
/// files, build files and the top-level docs. Released history in
/// CHANGELOG.md and the archived documents under docs/ and reviews/ are out
/// of scope.
///
/// Only product forms count, not the ordinary English word: the name as a
/// capitalised word, followed by "mail", "calendar" or "style" (optionally
/// after a space or hyphen), as a ".so"/".com" domain, or as an identifier
/// prefix. The scan walks the files on disk, not `git ls-files`, so an
/// untracked file in a local checkout is scanned too.
final class RemovedProductReferenceTests: XCTestCase {

    /// Built in pieces so this file does not match its own scan.
    private static let lower = "no" + "tion"
    private static let capitalised = "N" + "otion"

    private static let patterns: [NSRegularExpression] = [
        // name + mail / calendar / style, or a domain, in any case.
        try! NSRegularExpression(
            pattern: "\\b\(lower)(?:[ -]?(?:mail|calendar|style)|\\.(?:so|com))",
            options: [.caseInsensitive]),
        // The capitalised product name as a word, or as a type-name prefix
        // (`…MailSettings`, `…SwitchStyle`).
        try! NSRegularExpression(pattern: "\\b\(capitalised)(?:\\b|[A-Z])"),
        // A lower-camel identifier prefix (`…Accent`, `…Sidebar`).
        try! NSRegularExpression(pattern: "\\b\(lower)[A-Z]"),
    ]

    static func namesRemovedProduct(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    // MARK: - The matcher

    func testMatcherIgnoresTheEnglishWord() {
        for text in ["the \(Self.lower) of a thread", "a \(Self.lower)al amount",
                     "two different \(Self.lower)s of \"demo\""] {
            XCTAssertFalse(Self.namesRemovedProduct(text), text)
        }
    }

    func testMatcherCatchesEachProductForm() {
        let n = Self.capitalised, l = Self.lower
        for text in ["\(n) Mail", "\(n)-Mail-style", "\(l)mail", "\(n) Calendar",
                     "\(n)-style", "\(n) style", "calendar.\(l).so/meet", "www.\(l).com/help",
                     "Color.\(l)Accent", "\(n)SwitchStyle", "\(n)MailSettings.swift",
                     "Gmail/\(n) dock", "\(n)'s shutdown guide"] {
            XCTAssertTrue(Self.namesRemovedProduct(text), text)
        }
    }

    // MARK: - The tree

    func testRemovedProductIsNotNamedInTheProductTree() throws {
        let root = ForkIdentityTests.repoRoot
        var offenders: [String] = []
        for dir in ["Sources", "Tests", "scripts", ".github", "Config", "Design"] {
            let base = root.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.isRegularFileKey]) else {
                XCTFail("\(dir)/ not found under \(root.path)")
                continue
            }
            for case let url as URL in walker {
                let rel = String(url.path.dropFirst(root.path.count + 1))
                if Self.namesRemovedProduct(url.lastPathComponent) { offenders.append(rel) }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      let text = try? String(contentsOf: url, encoding: .utf8)
                else { continue }
                if Self.namesRemovedProduct(text) { offenders.append(rel) }
            }
        }
        for file in ["Makefile", "project.yml", "README.md", "CONTRIBUTING.md", "SECURITY.md"] {
            if Self.namesRemovedProduct(try ForkIdentityTests.repoFile(file)) {
                offenders.append(file)
            }
        }
        XCTAssertEqual(offenders, [], "removed product still referenced")
    }

    /// The scan must actually see the tree, or an empty result proves nothing.
    func testScanReachesTheSources() throws {
        let colors = try ForkIdentityTests.repoFile("Sources/MishMail/Support/Colors.swift")
        XCTAssertTrue(colors.contains("static let mailAccent"))
    }
}
