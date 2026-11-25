import XCTest

/// `scripts/update-dreamail.sh`: no inherited release channel, and no
/// rollback unless the recovery flag says so.
///
/// The script runs for real under bash against a fake installed app, with
/// `curl` and `codesign` replaced by stubs on PATH: the curl stub records
/// every call and serves the release metadata and assets the test chose, so
/// "no network call" and "nothing downloaded" are observable without any
/// network; the codesign stub records its arguments and reports the Team ID
/// the test chose. bash, python3, plutil, shasum and ditto are the host's.
final class UpdateScriptTests: XCTestCase {

    private var dir: URL!
    private var app: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateScriptTests-\(UUID().uuidString)", isDirectory: true)
        let bin = dir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }

        // `-o FILE URL` copies the asset named like the URL's last path
        // component from the assets directory, when the test put one there.
        try Self.writeExecutable(bin.appendingPathComponent("curl"), """
            #!/bin/bash
            printf '%s\\n' "$*" >> "$CURL_LOG"
            out=""; url=""
            while [ $# -gt 0 ]; do
              case "$1" in
                -o) out="$2"; shift 2 ;;
                *) url="$1"; shift ;;
              esac
            done
            case "$url" in *api.github.com*) cat "$RELEASE_JSON"; exit 0 ;; esac
            asset="$ASSETS/${url##*/}"
            [ -n "$out" ] && [ -f "$asset" ] && cp "$asset" "$out" && exit 0
            exit 22
            """)
        // Reports the Team ID the test chose; `--verify` is recorded and
        // fails unless the test says otherwise.
        try Self.writeExecutable(bin.appendingPathComponent("codesign"), """
            #!/bin/bash
            printf '%s\\n' "$*" >> "$CODESIGN_LOG"
            case " $* " in *" --verify "*) exit "${CODESIGN_VERIFY_STATUS:-1}" ;; esac
            echo "TeamIdentifier=${CODESIGN_TEAM-ABCDE12345}" >&2
            """)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        app = try Self.makeApp(in: dir, version: "0.7.0")
        try Data().write(to: curlLog)
        try Data().write(to: codesignLog)
    }

    // MARK: - Channel

    func testRefusesToRunWithoutAnExplicitRepository() throws {
        try publishLatest("0.8.0")
        let result = try runScript([app.path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("--repo"), result.stderr)
        XCTAssertEqual(try curlCalls(), [], "no request may be made without a chosen channel")
    }

    func testRefusesAnAdHocInstallBeforeAnyRequest() throws {
        try publishLatest("0.8.0")
        for team in ["", "not set"] {
            let result = try runScript(["--repo", "bateman/dreamail", app.path],
                                       env: ["CODESIGN_TEAM": team])
            XCTAssertNotEqual(result.status, 0, team)
            XCTAssertTrue(result.stderr.contains("ad-hoc"), result.stderr)
            XCTAssertEqual(try curlCalls(), [], team)
        }
    }

    func testRefusesReleaseAssetsOutsideTheRepositoryDownloads() throws {
        for zipURL in ["https://example.invalid/DreaMail-0.8.0.zip",
                       "http://github.com/bateman/dreamail/releases/download/v0.8.0/DreaMail-0.8.0.zip",
                       "https://github.com/someone/else/releases/download/v0.8.0/DreaMail-0.8.0.zip"] {
            try Data().write(to: curlLog)
            try publishLatest("0.8.0", zipURL: zipURL)
            let result = try runScript(["--repo", "bateman/dreamail", app.path])
            XCTAssertNotEqual(result.status, 0, zipURL)
            XCTAssertTrue(result.stderr.contains("is not under"), result.stderr)
            XCTAssertEqual(try curlCalls(), [Self.apiCall], "nothing downloaded from \(zipURL)")
        }
    }

    func testRefusesAMalformedRepository() throws {
        try publishLatest("0.8.0")
        for repo in ["ronboger", "https://github.com/owner/repo", "a/b/c", "owner/..", ""] {
            let result = try runScript(["--repo", repo, app.path])
            XCTAssertNotEqual(result.status, 0, repo)
            XCTAssertEqual(try curlCalls(), [], repo)
        }
    }

    // MARK: - Anti-rollback

    func testRefusesAnOlderReleaseBeforeDownloadingIt() throws {
        try publishLatest("0.6.9")
        let result = try runScript(["--repo", "bateman/dreamail", app.path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("not a newer version"), result.stderr)
        XCTAssertEqual(try curlCalls(), [Self.apiCall])
    }

    func testComparesVersionsNumericallyNotAsText() throws {
        // 0.6.10 is older than the installed 0.7.0; 0.10.0 is newer, although
        // it sorts below 0.7.0 as text.
        try publishLatest("0.6.10")
        XCTAssertNotEqual(try runScript(["--repo", "bateman/dreamail", app.path]).status, 0)
        XCTAssertEqual(try curlCalls(), [Self.apiCall])

        try Data().write(to: curlLog)
        try publishLatest("0.10.0")
        _ = try runScript(["--repo", "bateman/dreamail", app.path])
        XCTAssertEqual(try curlCalls().count, 2, "a newer release proceeds to the download")
    }

    func testSameVersionIsANoOp() throws {
        // "v0.7" and the installed "0.7.0" are the same version.
        for tag in ["0.7.0", "0.7"] {
            try Data().write(to: curlLog)
            try publishLatest(tag)
            let result = try runScript(["--repo", "bateman/dreamail", app.path])
            XCTAssertEqual(result.status, 0, tag)
            XCTAssertTrue(result.stdout.contains("Already on 0.7.0"), result.stdout)
            XCTAssertEqual(try curlCalls(), [Self.apiCall], tag)
        }
    }

    func testNewerReleaseIsDownloadedFromTheGivenRepositoryOverHTTPSOnly() throws {
        try publishLatest("0.7.1")
        _ = try runScript(["--repo", "bateman/dreamail", app.path])
        XCTAssertEqual(try curlCalls(), [Self.apiCall, Self.zipCall("0.7.1")])
    }

    func testRecoveryFlagAllowsADowngrade() throws {
        try publishLatest("0.6.0")
        let result = try runScript(["--repo", "bateman/dreamail", "--allow-downgrade", app.path])
        XCTAssertTrue(result.stderr.contains("--allow-downgrade"), result.stderr)
        XCTAssertEqual(try curlCalls(), [Self.apiCall, Self.zipCall("0.6.0")])
    }

    // MARK: - Signature

    /// The downloaded app is checked against an explicit requirement — Apple
    /// anchor, the installed app's Team ID in the leaf, the installed app's
    /// bundle id — and a failing check stops before anything is replaced.
    func testSignatureCheckIsAnchoredToTheInstalledTeamAndBundleIdentifier() throws {
        try publishLatest("0.8.0")
        try stageRelease("0.8.0")

        let result = try runScript(["--repo", "bateman/dreamail", app.path])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("not validly signed by team ABCDE12345"),
                      result.stderr)
        let calls = try codesignCalls()
        let verify = calls.filter { $0.hasPrefix("--verify") }
        XCTAssertEqual(verify.count, 1, "\(calls)")
        XCTAssertTrue(verify.first?.hasPrefix(
            "--verify --deep --strict -R=anchor apple generic and identifier "
            + "\"io.github.bateman.DreaMail\" and certificate leaf[subject.OU] = \"ABCDE12345\" ")
            == true, verify.first ?? "")
        XCTAssertEqual(UpdateChecker.bundleVersion(of: app), "0.7.0",
                       "the installed app must be untouched")
    }

    func testChecksumMismatchStopsBeforeTheSignatureCheck() throws {
        try publishLatest("0.8.0")
        try stageRelease("0.8.0", corruptChecksum: true)

        let result = try runScript(["--repo", "bateman/dreamail", app.path])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("SHA-256 did not match"), result.stderr)
        XCTAssertEqual(try codesignCalls().filter { $0.hasPrefix("--verify") }, [])
    }

    func testVersionComparisonHelper() throws {
        let cases: [(String, String, Bool)] = [
            ("0.7.1", "0.7.0", true), ("0.8", "0.7.9", true), ("1.0", "0.99.99", true),
            ("0.10.0", "0.9.0", true), ("0.7.0.1", "0.7", true),
            ("0.7.0", "0.7.0", false), ("0.7", "0.7.0", false), ("0.6.9", "0.7.0", false),
            ("0.7.0", "0.7.0.0", false),
            ("0.9.0", "0.10.0", false),
            // Never "newer": suffixed tags, junk, an unreadable installed version.
            ("0.8.0-beta.1", "0.7.0", false), ("v0.8.0", "0.7.0", false),
            ("", "0.7.0", false), ("0.8.0", "?", false), ("0..8", "0.7", false),
        ]
        for (candidate, current, newer) in cases {
            // $0 must not be the script's path, or sourcing would run main.
            let result = try run(["-c", "source \"$1\"; version_is_newer \"$2\" \"$3\"",
                                  "bash", Self.scriptPath, candidate, current])
            XCTAssertEqual(result.status == 0, newer, "\(candidate) vs \(current)")
        }
    }

    // MARK: - Helpers

    private static let apiCall = "-fsSL --proto =https --proto-redir =https "
        + "-H Accept: application/vnd.github+json https://api.github.com/repos/bateman/dreamail/releases/latest"

    private static func zipURL(_ version: String) -> String {
        "https://github.com/bateman/dreamail/releases/download/v\(version)/DreaMail-\(version).zip"
    }

    private static func zipCall(_ version: String) -> String {
        "-fsSL --proto =https --proto-redir =https -o release.zip \(zipURL(version))"
    }

    private static let scriptPath = ForkIdentityTests.repoRoot
        .appendingPathComponent("scripts/update-dreamail.sh").path

    private var curlLog: URL { dir.appendingPathComponent("curl.log") }
    private var codesignLog: URL { dir.appendingPathComponent("codesign.log") }
    private var releaseJSON: URL { dir.appendingPathComponent("release.json") }
    private var assets: URL { dir.appendingPathComponent("assets", isDirectory: true) }

    private func publishLatest(_ version: String, zipURL: String? = nil) throws {
        let zip = zipURL ?? Self.zipURL(version)
        let sums = "https://github.com/bateman/dreamail/releases/download/v\(version)/SHA256SUMS"
        let json = """
            {"tag_name": "v\(version)", "assets": [
              {"name": "DreaMail-\(version).zip", "browser_download_url": "\(zip)"},
              {"name": "SHA256SUMS", "browser_download_url": "\(sums)"}]}
            """
        try Data(json.utf8).write(to: releaseJSON)
    }

    /// Puts a zipped app of `version` and its SHA256SUMS where the curl stub
    /// serves them from.
    private func stageRelease(_ version: String, corruptChecksum: Bool = false) throws {
        let build = dir.appendingPathComponent("release-build", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let newApp = try Self.makeApp(in: build, version: version)
        let zipName = "DreaMail-\(version).zip"
        let zip = assets.appendingPathComponent(zipName)
        let pack = try run(["-c", "/usr/bin/ditto -c -k --keepParent \"$1\" \"$2\"",
                            "bash", newApp.path, zip.path])
        XCTAssertEqual(pack.status, 0, pack.stderr)
        let sum = try run(["-c", "/usr/bin/shasum -a 256 \"$1\" | awk '{print $1}'",
                           "bash", zip.path]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(sum.count, 64)
        let listed = corruptChecksum ? String(repeating: "0", count: 64) : sum
        try Data("\(listed)  \(zipName)\n".utf8)
            .write(to: assets.appendingPathComponent("SHA256SUMS"))
    }

    private static func makeApp(in parent: URL, version: String) throws -> URL {
        let app = parent.appendingPathComponent("DreaMail.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleShortVersionString": version,
                                   "CFBundleIdentifier": "io.github.bateman.DreaMail"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    private func curlCalls() throws -> [String] { try lines(of: curlLog) }
    private func codesignCalls() throws -> [String] { try lines(of: codesignLog) }

    private func lines(of url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private struct Result { let status: Int32; let stdout: String; let stderr: String }

    private func runScript(_ args: [String], env: [String: String] = [:]) throws -> Result {
        try run([Self.scriptPath] + args, env: env)
    }

    private func run(_ args: [String], env: [String: String] = [:]) throws -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = args
        proc.currentDirectoryURL = dir
        proc.environment = [
            "PATH": dir.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": dir.path,
            "TMPDIR": dir.path + "/",
            "CURL_LOG": curlLog.path,
            "CODESIGN_LOG": codesignLog.path,
            "RELEASE_JSON": releaseJSON.path,
            "ASSETS": assets.path,
        ].merging(env) { _, new in new }
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        // Read before waiting so a chatty run cannot fill the pipe and stall.
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return Result(status: proc.terminationStatus,
                      stdout: String(decoding: stdout, as: UTF8.self),
                      stderr: String(decoding: stderr, as: UTF8.self))
    }

    private static func writeExecutable(_ url: URL, _ text: String) throws {
        try Data((text + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
