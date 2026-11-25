import Foundation

/// Creating, editing and deleting Gmail filters (Settings → Gmail filters).
/// Each call throws a `GmailFilterError` for the sheet to show and updates
/// `filterCache` only with what Gmail confirmed. When the outcome is unknown
/// (timeout, 5xx), the list is read again from Gmail.
extension MailStore {

    func createFilter(_ draft: GmailFilterDraft, account accountId: String) async throws {
        try requireFilterEdits(accountId)
        do {
            let created = try await client(for: accountId).createFilter(draft.body)
            guard isKnownAccount(accountId) else { return }
            filterCache.apply(.created(created), account: accountId)
        } catch {
            throw await filterEditFailed(error, account: accountId)
        }
    }

    /// Create-then-delete (`GmailClient.replaceFilter`). When the delete
    /// fails both filters are listed, as they both exist on Gmail.
    func replaceFilter(_ original: GFilter, with draft: GmailFilterDraft,
                       account accountId: String) async throws {
        try requireFilterEdits(accountId)
        // Drafts, not bodies: label order and empty fields differ between
        // Gmail's copy and a re-encoding of the same filter.
        guard draft != GmailFilterDraft(original) else { return }
        do {
            let created = try await client(for: accountId)
                .replaceFilter(id: original.id, with: draft.body)
            guard isKnownAccount(accountId) else { return }
            filterCache.apply(.replaced(oldId: original.id, with: created), account: accountId)
        } catch {
            throw await filterEditFailed(error, account: accountId)
        }
    }

    func deleteFilter(_ filter: GFilter, account accountId: String) async throws {
        try requireFilterEdits(accountId)
        do {
            try await client(for: accountId).deleteFilter(id: filter.id)
            guard isKnownAccount(accountId) else { return }
            filterCache.apply(.deleted(id: filter.id), account: accountId)
        } catch {
            throw await filterEditFailed(error, account: accountId)
        }
    }

    /// Local messages the criteria would match, off the main actor. Throws
    /// when the local cache can't be read.
    func previewFilter(_ criteria: GFilter.Criteria,
                       account accountId: String) async throws -> GmailFilterPreview.Result {
        let pool = db
        return try await pool.read { db in
            try GmailFilterPreview.fetch(db, account: accountId, criteria: criteria)
        }
    }

    private func filterEditFailed(_ error: Error, account accountId: String) async -> GmailFilterError {
        let failure = GmailFilterError(error)
        guard isKnownAccount(accountId) else { return failure }
        filterCache.apply(failure: failure, account: accountId)
        if GmailFilterError.outcomeUnknown(error) {
            await ensureFiltersLoaded(for: accountId, force: true)
        }
        return failure
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
