import Foundation

/// What a build without AI features does about MCP state an earlier build
/// left behind. The server itself is refused in `MailStore.startMCPServer`;
/// this only cleans up, once per launch:
///
/// - the stored opt-in (`mcp.enabled`) is cleared, so building the features
///   back in later needs a fresh choice instead of silently restarting a
///   listener;
/// - a stale `mcp.json` is removed, so helper scripts see no advertised
///   server;
/// - if a server ever ran, the bearer token is marked for rotation: helpers
///   such as the launchd summarizer keep posting the old token to a port
///   that, while unbound, any local process could take. The next opt-in
///   mints a new token (`takeTokenRotation`). The Keychain is not touched
///   while the features are off.
enum MCPSwitchedOff {
    static let enabledKey = "mcp.enabled"
    static let rotateTokenKey = "mcp.rotateToken"

    /// Returns whether anything was left to clean up.
    @discardableResult
    static func cleanUp(defaults: UserDefaults, discoveryURL: URL,
                        fileManager: FileManager = .default) -> Bool {
        var serverEverRan = false
        if defaults.object(forKey: enabledKey) != nil {
            serverEverRan = defaults.bool(forKey: enabledKey)
            defaults.removeObject(forKey: enabledKey)
        }
        // A symlink is removed, never followed.
        if (try? fileManager.attributesOfItem(atPath: discoveryURL.path)) != nil {
            try? fileManager.removeItem(at: discoveryURL)
            serverEverRan = true
        }
        if serverEverRan {
            defaults.set(true, forKey: rotateTokenKey)
        }
        return serverEverRan
    }

    /// True once after `cleanUp` saw a server: the caller replaces the token.
    static func takeTokenRotation(defaults: UserDefaults) -> Bool {
        guard defaults.bool(forKey: rotateTokenKey) else { return false }
        defaults.removeObject(forKey: rotateTokenKey)
        return true
    }
}
