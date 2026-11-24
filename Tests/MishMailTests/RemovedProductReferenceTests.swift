import XCTest

/// MishMail no longer carries a migration path from, or a style borrowed by
/// name from, another mail product. Its name must not come back in code,
/// tests, scripts, build files or the README (released history in
/// CHANGELOG.md and archived documents under docs/ are out of scope).
final class RemovedProductReferenceTests: XCTestCase {

    /// Built in pieces so this file does not match its own scan.
    private static let removedName = "no" + "tion"

    func testRemovedProductIsNotNamedInCodeScriptsOrReadme() throws {
        let root = ForkIdentityTests.repoRoot
        var offenders: [String] = []
        for dir in ["Sources", "Tests", "scripts"] {
            let base = root.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.isRegularFileKey]) else {
                XCTFail("\(dir)/ not found under \(root.path)")
                continue
            }
            for case let url as URL in walker {
                let rel = String(url.path.dropFirst(root.path.count + 1))
                if url.lastPathComponent.lowercased().contains(Self.removedName) {
                    offenders.append(rel)
                }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      let text = try? String(contentsOf: url, encoding: .utf8)
                else { continue }
                if text.lowercased().contains(Self.removedName) { offenders.append(rel) }
            }
        }
        for file in ["Makefile", "project.yml", "README.md"] {
            if try ForkIdentityTests.repoFile(file).lowercased().contains(Self.removedName) {
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
