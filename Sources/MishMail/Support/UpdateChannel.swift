import Foundation

/// Where the in-app updater looks for releases: a GitHub `owner/repo`.
///
/// There is deliberately no default. A channel exists only when the build
/// was given one — `MISHMAIL_UPDATE_CHANNEL` in `Config/Local.xcconfig` or on
/// the `xcodebuild` command line, which lands in Info.plist under `infoKey`.
/// The tracked configuration leaves it empty, so a build from this
/// repository never contacts any releases API and never replaces itself.
///
/// The reason is the trust model in `UpdateChecker.evaluateTrust`: an ad-hoc
/// install (every local `make build` / `make install`) has no Team ID to pin,
/// so it would accept any notarized Developer ID build the channel served. An
/// inherited channel the fork does not control is therefore the one thing the
/// updater must never be pointed at by accident.
struct UpdateChannel: Equatable, Sendable {
    let owner: String
    let repository: String

    /// Info.plist key the build setting expands into.
    static let infoKey = "MishMailUpdateChannel"

    var slug: String { "\(owner)/\(repository)" }

    var latestReleaseURL: URL {
        // Both parts are validated to URL-safe characters in `init?`.
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!
    }

    /// Parses `owner/repo`. Anything else — empty, an unexpanded
    /// `$(MISHMAIL_UPDATE_CHANNEL)`, a URL, extra path segments, characters
    /// GitHub does not allow — is no channel at all, never a guess.
    init?(_ raw: String?) {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0]), repository = String(parts[1])
        guard Self.isValidOwner(owner), Self.isValidRepository(repository) else { return nil }
        self.owner = owner
        self.repository = repository
    }

    /// The channel a bundle was built with, if any.
    static func configured(in infoDictionary: [String: Any]?) -> UpdateChannel? {
        UpdateChannel(infoDictionary?[infoKey] as? String)
    }

    private static let alphanumerics: Set<Character> =
        Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    /// GitHub logins: 1–39 ASCII alphanumerics or single inner hyphens.
    private static func isValidOwner(_ s: String) -> Bool {
        guard (1...39).contains(s.count), !s.hasPrefix("-"), !s.hasSuffix("-"),
              !s.contains("--") else { return false }
        return s.allSatisfy { alphanumerics.contains($0) || $0 == "-" }
    }

    /// GitHub repository names: 1–100 of ASCII alphanumerics, `-`, `_`, `.`,
    /// and never `.` or `..`.
    private static func isValidRepository(_ s: String) -> Bool {
        guard (1...100).contains(s.count), s != ".", s != ".." else { return false }
        return s.allSatisfy { alphanumerics.contains($0) || "-_.".contains($0) }
    }
}
