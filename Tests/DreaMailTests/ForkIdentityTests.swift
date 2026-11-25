import XCTest

/// The fork's own identity: bundle identifiers that cannot collide with an
/// upstream install (separate sandbox container, defaults and Keychain
/// items), and a build configuration that ships with the updater disabled.
final class ForkIdentityTests: XCTestCase {

    /// Built in pieces so this file does not match its own scan.
    private static let upstreamPrefix = "dev." + "ronboger"
    /// The fork's bundle id before the rename to DreaMail (DEC-065), and the
    /// update-channel switch of that time: a leftover would key data on the
    /// old identity, or leave a switch that the build no longer reads.
    private static let formerForkID = "io.github.bateman." + "Mi" + "shMail"
    private static let formerChannelSwitch = "MISH" + "MAIL_UPDATE_CHANNEL"

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
            "io.github.bateman.DreaMail",
            "io.github.bateman.DreaMail.debug",
            "io.github.bateman.DreaMail.Relauncher",
        ])
    }

    /// The relauncher finds the app's sandbox container by bundle id alone,
    /// so it must name the Release app's id exactly.
    func testRelauncherContractNamesTheReleaseBundleIdentifier() throws {
        XCTAssertEqual(Relaunch.bundleID, "io.github.bateman.DreaMail")
        let project = try Self.repoFile("project.yml")
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER: \(Relaunch.bundleID)\n"))
    }

    /// Everything else keyed on the bundle id (Keychain fallback service, log
    /// subsystems, pasteboard names, container paths in scripts, launchd
    /// label) follows the fork's prefix.
    func testNoUpstreamBundleIdentifierLeftInCodeOrScripts() throws {
        XCTAssertEqual(try Self.filesNaming(Self.upstreamPrefix), [],
                       "upstream bundle id still referenced")
    }

    /// The same scan for the fork's own identifiers before the rename. The
    /// lower-case form covers the launchd label and the container paths.
    func testNoFormerForkIdentifierLeftInCodeOrScripts() throws {
        XCTAssertEqual(try Self.filesNaming(Self.formerForkID, caseInsensitive: true), [],
                       "former fork bundle id still referenced")
        XCTAssertEqual(try Self.filesNaming(Self.formerChannelSwitch), [],
                       "former update-channel switch still referenced")
    }

    /// Files under Sources, Tests, scripts and Config, plus the Makefile and
    /// project.yml, whose name or text contains `needle`.
    private static func filesNaming(_ needle: String,
                                    caseInsensitive: Bool = false) throws -> [String] {
        let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
        func names(_ text: String) -> Bool { text.range(of: needle, options: options) != nil }
        let root = Self.repoRoot
        var offenders: [String] = []
        for dir in ["Sources", "Tests", "scripts", "Config"] {
            let base = root.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.isRegularFileKey]) else {
                XCTFail("\(dir)/ not found under \(root.path)")
                continue
            }
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                let rel = String(url.path.dropFirst(root.path.count + 1))
                if names(url.lastPathComponent) { offenders.append(rel) }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if names(text) { offenders.append(rel) }
            }
        }
        for file in ["Makefile", "project.yml"] {
            if names(try Self.repoFile(file)) { offenders.append(file) }
        }
        return offenders
    }

    // MARK: - Update channel shipped by the tracked configuration

    func testTrackedConfigurationShipsWithoutAnUpdateChannel() throws {
        // Info.plist only forwards the build setting…
        let plistData = try Data(contentsOf: Self.repoRoot
            .appendingPathComponent("Sources/DreaMail/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: plistData, format: nil) as? [String: Any])
        XCTAssertEqual(plist[UpdateChannel.infoKey] as? String, "$(DREAMAIL_UPDATE_CHANNEL)")

        // …which the tracked xcconfig sets to empty, before Local.xcconfig.
        let xcconfig = try Self.repoFile("Config/Signing.xcconfig")
        let assignments = xcconfig.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && $0.hasPrefix("DREAMAIL_UPDATE_CHANNEL") }
        XCTAssertEqual(assignments, ["DREAMAIL_UPDATE_CHANNEL ="])

        // A target setting would silently override the xcconfig.
        XCTAssertFalse(try Self.repoFile("project.yml").contains("DREAMAIL_UPDATE_CHANNEL"))
    }

    // MARK: - Helpers

    /// …/Tests/DreaMailTests/ThisFile.swift → repo root.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func repoFile(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }
}
