import XCTest

/// The MCP helper scripts (`scripts/mcp-summarize.py`, `scripts/mcp_common.py`)
/// send mail text, a model API key and the MCP bearer token: plain HTTP only
/// to a literal loopback address, HTTPS otherwise, redirects held to the same
/// rule and origin, no key on the command line (F-05).
///
/// The cases live in `scripts/tests/test_mcp_endpoints.py`, next to the code
/// they test, and replace the scripts' opener with a recorder, so "nothing
/// was sent" is observable without any network. This runs them under the
/// host's python3, as `UpdateScriptTests` runs the update script under bash.
final class ScriptEndpointTests: XCTestCase {

    func testHelperScriptsRefuseRemoteHTTPAndForeignRedirects() throws {
        let result = try runPython(["-m", "unittest", "discover",
                                    "-s", "scripts/tests", "-p", "test_*.py", "-v"])
        XCTAssertEqual(result.status, 0, result.output)
        // unittest prints its verdict last; a discovery that found nothing
        // would also exit 0.
        XCTAssertTrue(result.output.contains("\nOK"), result.output)
        XCTAssertFalse(result.output.contains("Ran 0 tests"), result.output)
    }

    // MARK: - Helpers

    private func runPython(_ args: [String]) throws -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3"] + args
        proc.currentDirectoryURL = ForkIdentityTests.repoRoot
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptEndpointTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        proc.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            // No real token file or mcp.json can be picked up.
            "HOME": home.path,
            "PYTHONDONTWRITEBYTECODE": "1",
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// TEMPORARY (reverted): proves the CI warning gate fails on a test warning.
func ciWarningGateTestProbe() {
    let unusedTestProbe = 1
}
