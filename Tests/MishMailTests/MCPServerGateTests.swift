import XCTest

/// The MCP server's off switch, checked against the real code.
///
/// `MailStore` (and `MCPServer`, the NWListener) are app-only: the hostless
/// test target cannot build or launch them. So this reads the source and pins
/// the wiring instead: `startMCPServer` returns at its first statement when
/// the build has the AI features off, and it is the only place a server is
/// created, bound, or advertised in `mcp.json`. Deleting the guard, or adding
/// a second construction site, fails here.
final class MCPServerGateTests: XCTestCase {

    private static let mailStorePath = "Sources/MishMail/App/MailStore.swift"

    private func source(_ path: String) throws -> String {
        try ForkIdentityTests.repoFile(path)
    }

    /// Lines of the body of `func <name>(` in `text`, by brace matching.
    private func body(of name: String, in text: String) throws -> [String] {
        let start = try XCTUnwrap(text.range(of: "func \(name)() {"),
                                  "\(name) not found")
        var depth = 0
        var lines: [String] = []
        var current = ""
        var started = false
        for ch in text[start.lowerBound...] {
            if ch == "{" { depth += 1; started = true }
            if ch == "}" { depth -= 1 }
            if ch == "\n" { lines.append(current); current = "" } else { current.append(ch) }
            if started && depth == 0 { lines.append(current); break }
        }
        return lines
    }

    func testStartMCPServerReturnsFirstWhenTheFeaturesAreOff() throws {
        let lines = try body(of: "startMCPServer", in: source(Self.mailStorePath))
            .dropFirst()   // the signature line
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        XCTAssertEqual(lines.first, "guard AIFeatures.isEnabled else { return }",
                       "the gate must come before the token read, the bind and mcp.json")
    }

    func testTheServerIsCreatedAndAdvertisedOnlyInStartMCPServer() throws {
        let store = try source(Self.mailStorePath)
        let start = try body(of: "startMCPServer", in: store).joined(separator: "\n")
        for needle in ["MCPServer(tools:", ".start(token:", "writeMCPDiscovery(port:"] {
            XCTAssertEqual(store.components(separatedBy: needle).count - 1,
                           needle == "writeMCPDiscovery(port:" ? 2 : 1,
                           "\(needle) outside startMCPServer") // 2 = call + definition
            XCTAssertTrue(start.contains(needle), "\(needle) missing from startMCPServer")
        }
        // No other app file builds a server.
        let root = ForkIdentityTests.repoRoot.appendingPathComponent("Sources/MishMail")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root,
                                                                  includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(ForkIdentityTests.repoRoot.path.count + 1))
            guard rel != Self.mailStorePath else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("MCPServer(tools:"), "\(rel) creates an MCP server")
            XCTAssertFalse(text.contains("mcp.json\")"), "\(rel) names the discovery file")
        }
    }

    /// The launch path cleans up instead of starting, and the opt-in setter
    /// stores nothing, in a build with the features off.
    func testLaunchPathAndSetterAreGated() throws {
        let store = try source(Self.mailStorePath)
        XCTAssertTrue(store.contains("""
                if !AIFeatures.isEnabled {
                    MCPSwitchedOff.cleanUp(defaults: .standard, discoveryURL: mcpDiscoveryURL)
                } else if isMCPEnabled, !isShuttingDown {
                    startMCPServer()
                }
        """))
        XCTAssertTrue(store.contains("""
                    guard AIFeatures.isEnabled else {
                        stopMCPServer()
                        return
                    }
                    UserDefaults.standard.set(newValue, forKey: Self.mcpEnabledKey)
        """))
    }
}
