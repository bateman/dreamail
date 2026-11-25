import Foundation

/// Creating, editing and deleting Gmail filters (Settings → Gmail filters).
/// Each call throws a `GmailFilterError` for the sheet to show and updates
/// `filterCache` only with what Gmail confirmed.
extension MailStore {

    func createFilter(_ body: GFilter.Body, account accountId: String) async throws {
        try requireFilterEdits(accountId)
        do {
            let created = try await client(for: accountId).createFilter(body)
            guard isKnownAccount(accountId) else { return }
            filterCache.inserted(created, account: accountId)
        } catch {
            throw GmailFilterError(error)
        }
    }

    /// Create-then-delete (`GmailClient.replaceFilter`). When the delete
    /// fails both filters are listed, as they both exist on Gmail.
    func replaceFilter(_ original: GFilter, with body: GFilter.Body,
                       account accountId: String) async throws {
        try requireFilterEdits(accountId)
        guard body != original.body else { return }
        do {
            let created = try await client(for: accountId)
                .replaceFilter(id: original.id, with: body)
            guard isKnownAccount(accountId) else { return }
            filterCache.replaced(id: original.id, with: created, account: accountId)
        } catch {
            let failure = GmailFilterError(error)
            if case .oldFilterKept(let created, _) = failure, isKnownAccount(accountId) {
                filterCache.inserted(created, account: accountId)
            }
            throw failure
        }
    }

    func deleteFilter(_ filter: GFilter, account accountId: String) async throws {
        try requireFilterEdits(accountId)
        do {
            try await client(for: accountId).deleteFilter(id: filter.id)
            guard isKnownAccount(accountId) else { return }
            filterCache.removed(id: filter.id, account: accountId)
        } catch {
            throw GmailFilterError(error)
        }
    }

    /// Local messages the criteria would match, off the main actor.
    func previewFilter(_ criteria: GFilter.Criteria,
                       account accountId: String) async -> GmailFilterPreview.Result? {
        let pool = db
        return try? await pool.read { db in
            try GmailFilterPreview.fetch(db, account: accountId, criteria: criteria)
        }
    }

    private func requireFilterEdits(_ accountId: String) throws {
        if demoMode {
            throw GmailFilterError.other("Filters can't be changed in the fictional inbox.")
        }
        guard isKnownAccount(accountId) else {
            throw GmailFilterError.other("This account is no longer in MishMail.")
        }
    }
}
