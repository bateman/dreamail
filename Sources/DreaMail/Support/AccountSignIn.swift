import Foundation

/// "Add Google Account…" up to the stored account row. The first sync is not
/// part of it: it runs afterwards as ordinary background work, so the
/// control reads "Add Google Account…" again as soon as the row is stored.
///
/// Cancellable while it waits for the browser and the profile. Once both are
/// back, storing the token and the account row runs as one unit that a
/// cancel does not cut in half: either nothing is stored, or both are.
enum AccountSignIn {
    struct Profile: Equatable, Sendable {
        var email: String
        var name: String?
        var picture: String?
    }

    /// - Parameters:
    ///   - authorize: the browser sign-in; returns (refresh, access) tokens.
    ///   - profile: the signed-in account, read with the access token.
    ///   - store: keeps the refresh token and the account row. Returns false
    ///     when it chose not to (demo exit refused). Not cancelled by a
    ///     cancel of the caller.
    /// - Returns: the stored profile; nil when `store` returned false.
    /// - Throws: `CancellationError` when cancelled before `store` ran.
    static func connect(
        authorize: () async throws -> (refreshToken: String, accessToken: String),
        profile: (String) async throws -> Profile,
        store: @escaping @Sendable (String, Profile) async throws -> Bool
    ) async throws -> Profile? {
        let tokens = try await authorize()
        try Task.checkCancellation()
        let info = try await profile(tokens.accessToken)
        try Task.checkCancellation()
        let refresh = tokens.refreshToken
        // Unstructured on purpose: a cancel arriving now must not stop it
        // between the Keychain write and the database insert.
        let stored = try await Task { try await store(refresh, info) }.value
        return stored ? info : nil
    }
}

/// A new account's first sync, tracked like the other syncs (quit and
/// account removal cancel and await it). `id` tells a later one apart.
struct FirstSyncHandle {
    let id: UUID
    let task: Task<Void, Never>
}
