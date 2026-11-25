import XCTest

/// The OpenPGP library is linked into the app whatever the build switch
/// says, so its licences ship inside the app: the copy in
/// `Sources/DreaMail/Licenses` is the one the pinned package publishes, and
/// the built app carries it. Also prints the app's size for the record.
final class PGPBundleTests: XCTestCase {
    private static let shipped = ["OpenPGP-ThirdPartyLicenses.txt": "THIRD_PARTY_LICENSES.md",
                                  "OpenPGP-LICENSE.txt": "LICENSE"]

    func testTheBuiltAppShipsTheLibrarysLicencesAsPinned() throws {
        // Fails, never skips, without a built app: `make build` first (CI
        // builds before it tests).
        let app = try XCTUnwrap(UpdateVerifySmokeTests.builtAppURL(),
                                "No built DreaMail app in DerivedData; run `make build` first")
        let root = ForkIdentityTests.repoRoot
        // `make build` resolves packages here; the checkout is the pinned
        // commit of dreamail-openpgp.
        let checkout = root.appendingPathComponent("build/dd.noindex/SourcePackages/checkouts/dreamail-openpgp")
        for (name, upstream) in Self.shipped {
            let vendored = try Data(contentsOf: root.appendingPathComponent("Sources/DreaMail/Licenses/\(name)"))
            let inApp = try Data(contentsOf: app.appendingPathComponent("Contents/Resources/\(name)"))
            XCTAssertEqual(inApp, vendored, "\(name) in the built app")
            if app.path.contains("/build/dd.noindex/") {
                let pinned = try Data(contentsOf: checkout.appendingPathComponent(upstream))
                XCTAssertEqual(vendored, pinned, "\(name) must match the pinned package's \(upstream)")
            }
        }

        // For the PR record: the size of what was built.
        let executable = app.appendingPathComponent("Contents/MacOS")
        let binaries = try FileManager.default.contentsOfDirectory(at: executable, includingPropertiesForKeys: [.fileSizeKey])
        for binary in binaries {
            let size = try binary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            print("PGPBundleTests size: \(binary.lastPathComponent) \(size) bytes")
        }
    }
}
