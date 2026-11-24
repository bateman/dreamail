import GRDB

/// How mail deletes reach the full-text index (`message_fts`).
///
/// The index deletes securely (migration v49): each deleted message's terms
/// are cut out of the segment that holds them, at about half a millisecond
/// per message under SQLCipher. That is nothing for the few rows a sync pass
/// removes, but it turns a bulk delete (pruning local mail, removing an
/// account, a mass delete in Gmail) into a write transaction of tens of
/// seconds. For those, the per-row work is suspended for the transaction and
/// one `optimize` at the end rewrites the index into a single segment
/// without the deleted entries; the blocks it frees are zeroed
/// (`secure_delete`). Either way, when the transaction commits, no deleted
/// term is left in the index. The setting is stored in the index's config
/// table, so a rollback restores it with everything else.
enum SearchIndexDeletes {
    /// Deleted messages from which the bulk path is used. `optimize` costs
    /// roughly a rewrite of the whole index (subjects and headers only), so
    /// below this the per-row path is cheaper.
    static let bulkThreshold = 500

    /// Runs `body`, which deletes about `messages` message rows, on the
    /// path that suits that many. Must run inside a write transaction.
    static func deleting<T>(_ db: Database, messages: Int, _ body: () throws -> T) throws -> T {
        guard messages >= bulkThreshold else { return try body() }
        try setSecureDelete(db, on: false)
        let result = try body()
        try db.execute(sql: "INSERT INTO message_fts(message_fts) VALUES('optimize')")
        try setSecureDelete(db, on: true)
        return result
    }

    private static func setSecureDelete(_ db: Database, on: Bool) throws {
        try db.execute(
            sql: "INSERT INTO message_fts(message_fts, rank) VALUES('secure-delete', ?)",
            arguments: [on ? 1 : 0])
    }
}
