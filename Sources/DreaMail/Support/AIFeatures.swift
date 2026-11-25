import Foundation

/// Build-time master switch for every AI feature and the local MCP server.
///
/// Off in the shipped configuration. The value comes from the build setting
/// `DREAMAIL_AI_FEATURES`, which Info.plist expands under `infoKey`; the
/// tracked `Config/Signing.xcconfig` leaves it empty, and only an untracked
/// `Config/Local.xcconfig` (or the `xcodebuild` command line) can set it to
/// `YES`. It is deliberately not a preference: a stray `defaults write` must
/// not be able to start a listener or send mail text to a model provider.
///
/// With the switch off:
/// - no AI surface is offered (Ask AI, Handle with AI, compose drafting
///   and suggested replies, thread summaries, AI sorting and grouping, the
///   AI/MCP pane in Settings, their palette entries and shortcuts);
/// - `LLMTransport.live`, the one network path for every AI request
///   (providers, custom endpoints, model listing, provider sign-in and
///   refresh, the Ollama daemon), refuses before anything is sent;
///   `LLMClient` and `LLMTaskRunner` also refuse before a request is built
///   or a stored credential is read, and `LLMOAuthFlow.signIn` before a
///   listener or a browser opens;
/// - `MailStore.startMCPServer` returns first, whatever `mcp.enabled` says,
///   so no listener is bound and no `mcp.json` written; at launch
///   `MCPSwitchedOff` clears an earlier build's opt-in and discovery file.
///
/// The code behind the switch is kept, and its tests keep running: the
/// gated types take the state as a parameter so tests can exercise both.
enum AIFeatures {
    /// Info.plist key the build setting expands into.
    static let infoKey = "DreaMailAIFeatures"

    /// The state this process was built with. Read once; it cannot change
    /// while the app runs.
    static let isEnabled: Bool = configured(in: Bundle.main.infoDictionary)

    /// True only for an explicit yes. Empty, missing, an unexpanded
    /// `$(DREAMAIL_AI_FEATURES)`, or anything unrecognised is off.
    static func configured(in infoDictionary: [String: Any]?) -> Bool {
        isOn(infoDictionary?[infoKey] as? String)
    }

    static func isOn(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "true", "1": return true
        default: return false
        }
    }

    /// What a refused AI action says, when it says anything.
    static let disabledMessage = "AI features are turned off in this build."
}
