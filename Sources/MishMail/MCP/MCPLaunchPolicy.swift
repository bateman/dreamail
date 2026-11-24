import Foundation

/// Whether the in-process MCP server may run.
///
/// The build-time `AIFeatures` switch wins over everything stored: with it
/// off the server never starts — not at launch, not from the Settings toggle,
/// not from a port change — even when `mcp.enabled` is true in the defaults
/// (an earlier build's choice, or a `defaults write`). No listener is bound
/// and no `mcp.json` discovery file is written.
///
/// `MailStore.startMCPServer` is the only place a server is created, and it
/// asks `startIfAllowed`; the launch path asks `shouldStartAtLaunch`.
enum MCPLaunchPolicy {
    /// The stored opt-in (Settings → AI → MCP).
    static let enabledKey = "mcp.enabled"

    /// The server may run at all in this build.
    static func mayRun(aiFeatures: Bool = AIFeatures.isEnabled) -> Bool {
        aiFeatures
    }

    /// The launch path: the build allows it and the user opted in.
    static func shouldStartAtLaunch(aiFeatures: Bool = AIFeatures.isEnabled,
                                    defaults: UserDefaults = .standard) -> Bool {
        mayRun(aiFeatures: aiFeatures) && defaults.bool(forKey: enabledKey)
    }

    /// Runs `start` only when the build allows a server. Returns whether it ran.
    @discardableResult
    static func startIfAllowed(aiFeatures: Bool = AIFeatures.isEnabled,
                               start: () throws -> Void) rethrows -> Bool {
        guard mayRun(aiFeatures: aiFeatures) else { return false }
        try start()
        return true
    }
}
