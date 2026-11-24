import XCTest

/// `scripts/update-mishmail.sh`: no inherited release channel, and no
/// rollback unless the recovery flag says so.
///
/// The script runs for real under bash against a fake installed app, with
/// `curl` and `codesign` replaced by stubs on PATH: the curl stub records
/// every URL and serves the release metadata the test chose, so "no network
/// call" and "nothing downloaded" are observable without any network.
final class UpdateScriptTests: XCTestCase {

    private var dir: URL!
    private var app: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateScriptTests-\(UUID().uuidString)", isDirectory: true)
        let bin = dir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }

        try Self.writeExecutable(bin.appendingPathComponent("curl"), """
            #!/bin/bash
            printf '%s\\n' "$*" >> "$CURL_LOG"
            for arg in "$@"; do
              case "$arg" in *api.github.com*) cat "$RELEASE_JSON"; exit 0 ;; esac
            done
            exit 22
            """)
        // Team-signed as far as the script can tell; the real signature
        // checks come after everything these tests are about.
        try Self.writeExecutable(bin.appendingPathComponent("codesign"), """
            #!/bin/bash
            echo "TeamIdentifier=ABCDE12345" >&2
            """)

        app = dir.appendingPathComponent("MishMail.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleShortVersionString": "0.7.0",
                                   "CFBundleIdentifier": "io.github.bateman.MishMail"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data().write(to: curlLog)
    }

    // MARK: - Channel

    func testRefusesToRunWithoutAnExplicitRepository() throws {
        try publishLatest("0.8.0")
        let result = try runScript([app.path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("--repo"), result.stderr)
        XCTAssertEqual(try curlCalls(), [], "no request may be made without a chosen channel")
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
        let result = try runScript(["--repo", "bateman/mishmail", app.path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("not a newer version"), result.stderr)
        XCTAssertEqual(try curlCalls(), [Self.apiCall])
    }

    func testComparesVersionsNumericallyNotAsText() throws {
        // 0.6.10 is older than the installed 0.7.0; 0.10.0 is newer, although
        // it sorts below 0.7.0 as text.
        try publishLatest("0.6.10")
        XCTAssertNotEqual(try runScript(["--repo", "bateman/mishmail", app.path]).status, 0)
        XCTAssertEqual(try curlCalls(), [Self.apiCall])

        try Data().write(to: curlLog)
        try publishLatest("0.10.0")
        _ = try runScript(["--repo", "bateman/mishmail", app.path])
        XCTAssertEqual(try curlCalls().count, 2, "a newer release proceeds to the download")
    }

    func testSameVersionIsANoOp() throws {
        try publishLatest("0.7.0")
        let result = try runScript(["--repo", "bateman/mishmail", app.path])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("Already on 0.7.0"), result.stdout)
        XCTAssertEqual(try curlCalls(), [Self.apiCall])
    }

    func testNewerReleaseIsDownloadedFromTheGivenRepository() throws {
        try publishLatest("0.7.1")
        _ = try runScript(["--repo", "bateman/mishmail", app.path])
        XCTAssertEqual(try curlCalls(), [
            Self.apiCall,
            "-fsSL -o MishMail-0.7.1.zip https://example.invalid/MishMail-0.7.1.zip",
        ])
    }

    func testRecoveryFlagAllowsADowngrade() throws {
        try publishLatest("0.6.0")
        let result = try runScript(["--repo", "bateman/mishmail", "--allow-downgrade", app.path])
        XCTAssertTrue(result.stderr.contains("--allow-downgrade"), result.stderr)
        XCTAssertEqual(try curlCalls(), [
            Self.apiCall,
            "-fsSL -o MishMail-0.6.0.zip https://example.invalid/MishMail-0.6.0.zip",
        ])
    }

    func testVersionComparisonHelper() throws {
        let cases: [(String, String, Bool)] = [
            ("0.7.1", "0.7.0", true), ("0.8", "0.7.9", true), ("1.0", "0.99.99", true),
            ("0.10.0", "0.9.0", true), ("0.7.0.1", "0.7", true),
            ("0.7.0", "0.7.0", false), ("0.7", "0.7.0", false), ("0.6.9", "0.7.0", false),
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

    private static let apiCall =
        "-fsSL -H Accept: application/vnd.github+json https://api.github.com/repos/bateman/mishmail/releases/latest"

    private static let scriptPath = ForkIdentityTests.repoRoot
        .appendingPathComponent("scripts/update-mishmail.sh").path

    private var curlLog: URL { dir.appendingPathComponent("curl.log") }
    private var releaseJSON: URL { dir.appendingPathComponent("release.json") }

    private func publishLatest(_ version: String) throws {
        let json = """
            {"tag_name": "v\(version)", "assets": [
              {"name": "MishMail-\(version).zip", "browser_download_url": "https://example.invalid/MishMail-\(version).zip"},
              {"name": "SHA256SUMS", "browser_download_url": "https://example.invalid/SHA256SUMS"}]}
            """
        try Data(json.utf8).write(to: releaseJSON)
    }

    private func curlCalls() throws -> [String] {
        try String(contentsOf: curlLog, encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    private struct Result { let status: Int32; let stdout: String; let stderr: String }

    private func runScript(_ args: [String]) throws -> Result {
        try run([Self.scriptPath] + args)
    }

    private func run(_ args: [String]) throws -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = args
        proc.currentDirectoryURL = dir
        proc.environment = [
            "PATH": dir.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": dir.path,
            "TMPDIR": dir.path + "/",
            "CURL_LOG": curlLog.path,
            "RELEASE_JSON": releaseJSON.path,
        ]
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
