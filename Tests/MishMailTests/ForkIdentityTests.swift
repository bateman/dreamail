import XCTest

/// The fork's own identity: bundle identifiers that cannot collide with an
/// upstream install (separate sandbox container, defaults and Keychain
/// items), and a build configuration that ships with the updater disabled.
final class ForkIdentityTests: XCTestCase {

    static let prefix = "io.github.bateman."
    /// Built in pieces so this file does not match its own scan.
    private static let upstreamPrefix = "dev." + "ronboger"

    // MARK: - Bundle identifiers

    func testProjectUsesTheForkBundleIdentifiers() throws {
        let project = try Self.repoFile("project.yml")
        XCTAssertFalse(project.contains(Self.upstreamPrefix),
                       "project.yml still names the upstream bundle id")
        XCTAssertTrue(project.contains("bundleIdPrefix: io.github.bateman\n"))

        let ids = project.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("PRODUCT_BUNDLE_IDENTIFIER:") else { return nil }
            return trimmed.dropFirst("PRODUCT_BUNDLE_IDENTIFIER:".count)
                .trimmingCharacters(in: .whitespaces)
        }
        XCTAssertEqual(Set(ids), [
            "io.github.bateman.MishMail",
            "io.github.bateman.MishMail.debug",
            "io.github.bateman.MishMail.Relauncher",
        ])
    }

    /// The relauncher finds the app's sandbox container by bundle id alone,
    /// so it must name the Release app's id exactly.
    func testRelauncherContractNamesTheReleaseBundleIdentifier() throws {
        XCTAssertEqual(Relaunch.bundleID, "io.github.bateman.MishMail")
        let project = try Self.repoFile("project.yml")
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER: \(Relaunch.bundleID)\n"))
    }

    /// Everything else keyed on the bundle id (Keychain fallback service, log
    /// subsystems, pasteboard names, container paths in scripts, launchd
    /// label) follows the fork's prefix.
    func testNoUpstreamBundleIdentifierLeftInCodeOrScripts() throws {
        // Owned by a parallel change; it moves to the fork prefix there.
        let pendingElsewhere: Set<String> = ["Sources/MishMail/Support/DiagnosticLog.swift"]
        let root = Self.repoRoot
        var offenders: [String] = []
        for dir in ["Sources", "Tests", "scripts", "Config"] {
            let base = root.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                let rel = String(url.path.dropFirst(root.path.count + 1))
                if pendingElsewhere.contains(rel) { continue }
                if url.lastPathComponent.contains(Self.upstreamPrefix) { offenders.append(rel) }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if text.contains(Self.upstreamPrefix) { offenders.append(rel) }
            }
        }
        for file in ["Makefile", "project.yml"] {
            if try Self.repoFile(file).contains(Self.upstreamPrefix) { offenders.append(file) }
        }
        XCTAssertEqual(offenders, [], "upstream bundle id still referenced")
    }

    // MARK: - Update channel shipped by the tracked configuration

    func testTrackedConfigurationShipsWithoutAnUpdateChannel() throws {
        // Info.plist only forwards the build setting…
        let plistData = try Data(contentsOf: Self.repoRoot
            .appendingPathComponent("Sources/MishMail/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: plistData, format: nil) as? [String: Any])
        XCTAssertEqual(plist[UpdateChannel.infoKey] as? String, "$(MISHMAIL_UPDATE_CHANNEL)")

        // …which the tracked xcconfig sets to empty, before Local.xcconfig.
        let xcconfig = try Self.repoFile("Config/Signing.xcconfig")
        let assignments = xcconfig.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && $0.hasPrefix("MISHMAIL_UPDATE_CHANNEL") }
        XCTAssertEqual(assignments, ["MISHMAIL_UPDATE_CHANNEL ="])

        // A target setting would silently override the xcconfig.
        XCTAssertFalse(try Self.repoFile("project.yml").contains("MISHMAIL_UPDATE_CHANNEL"))
    }

    /// The app CI just built (it builds before it tests): fork bundle id, and
    /// an expanded, empty channel — so `UpdateChecker.shared` is disabled.
    func testBuiltAppHasTheForkIdentityAndNoUpdateChannel() throws {
        guard let app = UpdateVerifySmokeTests.builtAppURL() else {
            throw XCTSkip("no built MishMail app; run `make build` first (CI does)")
        }
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: data, format: nil) as? [String: Any])

        let bundleID = try XCTUnwrap(info["CFBundleIdentifier"] as? String)
        XCTAssertTrue(bundleID.hasPrefix(Self.prefix), bundleID)
        XCTAssertEqual(info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String,
                       app.deletingPathExtension().lastPathComponent)

        XCTAssertEqual(info[UpdateChannel.infoKey] as? String, "",
                       "the shipped build must carry an empty update channel")
        XCTAssertNil(UpdateChannel.configured(in: info))
    }

    // MARK: - Helpers

    /// …/Tests/MishMailTests/ThisFile.swift → repo root.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func repoFile(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }
}
