import XCTest

/// The in-app updater accepts only the same app: the downloaded bundle's
/// `CFBundleIdentifier` must equal the running app's, not merely come from
/// the same publisher.
final class UpdateBundleIdentifierTests: XCTestCase {

    func testBundleIdentifierIsReadFromTheBundlesInfoPlist() throws {
        let app = try makeBundle(id: "io.github.bateman.DreaMail")
        XCTAssertEqual(UpdateChecker.bundleIdentifier(of: app), "io.github.bateman.DreaMail")
        XCTAssertNil(UpdateChecker.bundleIdentifier(
            of: app.deletingLastPathComponent().appendingPathComponent("Missing.app")))
    }

    func testUpdateForADifferentBundleIdentifierIsRejected() async throws {
        let (zip, builtID) = try zippedBuiltApp()
        let running = try makeBundle(id: "io.github.bateman.SomeOtherApp")

        do {
            _ = try await UpdateChecker.stageAndVerify(
                downloadedZip: zip, assetName: "DreaMail-99.99.99.zip", checksumURL: nil,
                expectedVersion: "99.99.99", runningAppURL: running, workRoot: scratch)
            XCTFail("an update for another bundle id must not verify")
        } catch {
            XCTAssertEqual(error as? UpdateChecker.UpdateError,
                           .bundleIdentifierMismatch(expected: "io.github.bateman.SomeOtherApp",
                                                     found: builtID))
        }
    }

    func testRunningAppWithoutABundleIdentifierAcceptsNothing() async throws {
        let (zip, builtID) = try zippedBuiltApp()
        let running = try makeBundle(id: nil)

        do {
            _ = try await UpdateChecker.stageAndVerify(
                downloadedZip: zip, assetName: "DreaMail-99.99.99.zip", checksumURL: nil,
                expectedVersion: "99.99.99", runningAppURL: running, workRoot: scratch)
            XCTFail("with no running bundle id there is nothing to match")
        } catch {
            XCTAssertEqual(error as? UpdateChecker.UpdateError,
                           .bundleIdentifierMismatch(expected: nil, found: builtID))
        }
    }

    /// Matching ids get past this check: the pipeline goes on and fails at
    /// the next one (the version pin), not here.
    func testMatchingBundleIdentifierPassesOnToTheVersionPin() async throws {
        let (zip, builtID) = try zippedBuiltApp()
        let running = try makeBundle(id: builtID)

        do {
            _ = try await UpdateChecker.stageAndVerify(
                downloadedZip: zip, assetName: "DreaMail-99.99.99.zip", checksumURL: nil,
                expectedVersion: "99.99.99", runningAppURL: running, workRoot: scratch)
            XCTFail("the built app is not version 99.99.99")
        } catch UpdateChecker.UpdateError.versionMismatch(let expected, _) {
            XCTAssertEqual(expected, "99.99.99")
        }
    }

    // MARK: - Fixtures

    private lazy var scratch: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateBundleIdentifierTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }()

    /// A bundle that only has an Info.plist: enough to stand in for the
    /// running app, whose identifier is all this check reads.
    private func makeBundle(id: String?) throws -> URL {
        let app = scratch.appendingPathComponent("Running-\(UUID().uuidString).app",
                                                 isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleShortVersionString": "0.7.0"]
        if let id { info["CFBundleIdentifier"] = id }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    /// The app CI just built (it builds before it tests), zipped the way
    /// `make release` does: a real, validly signed bundle for the pipeline.
    private func zippedBuiltApp() throws -> (zip: URL, bundleID: String) {
        guard let app = UpdateVerifySmokeTests.builtAppURL() else {
            throw XCTSkip("No built DreaMail app in DerivedData; run `make build` first")
        }
        let id = try XCTUnwrap(UpdateChecker.bundleIdentifier(of: app))
        let zip = scratch.appendingPathComponent("download-\(UUID().uuidString).tmp")
        let pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        pack.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        try pack.run()
        pack.waitUntilExit()
        XCTAssertEqual(pack.terminationStatus, 0, "ditto zip failed")
        return (zip, id)
    }
}
