import CryptoKit
import Foundation
import GRDB

/// Inline (`cid:`) images of messages, kept in the encrypted database so a
/// conversation whose images were resolved once paints them without a Gmail
/// attachment request on a later open, after a relaunch too.
///
/// What is stored: the bytes of each raster image part a message's HTML
/// references as `src="cid:…"`, once per part, with a sanitized MIME type
/// (never SVG, never a non-image part). Not the base64-inlined HTML: that is
/// rebuilt from the stored body and these bytes, off the main actor. Remote
/// (http/https) images are never stored here.
///
/// Key: the part's attachment row (`attachmentId`, unique and never reused:
/// the column is AUTOINCREMENT) plus its message and Content-ID. Two more
/// columns are kept as defence in depth: the account (lookups and the
/// account purge name it, so a row can never answer for another account even
/// if an id were wrong) and a digest of the body the images were resolved
/// from (a body rewritten by any path that kept its attachment rows is a
/// miss, never stale images). A sender chooses Content-IDs, so a Content-ID
/// alone is never a key.
///
/// Deleted means gone: every row cascades with its attachment row, its
/// message and its account, so whatever deletes those (a sync delete, a
/// local prune, a discarded draft, a content re-fetch that replaces the
/// attachment rows, an account removal) deletes the images too, under the
/// same `secure_delete` and WAL scrub as the rest of the mail. Account
/// removal also deletes them by name.
///
/// Bounded: `totalBudgetBytes` overall, least recently used message first,
/// and `perMessageBytes` per message.
enum InlineImageCache {
    static let tableName = "inlineImage"

    /// Total image bytes kept. Eviction removes whole messages, least
    /// recently used first, until the total is back under this.
    static let totalBudgetBytes = 200 * 1_024 * 1_024

    /// Image bytes of one message, together. The in-memory rule
    /// (`CIDInlineCachePolicy.maximumBytes`) caps the base64-inlined HTML at
    /// 4 MiB; base64 grows bytes by 4/3, so 3 MiB of images is what fits
    /// that cap. A larger message re-downloads its images, as before.
    static let perMessageBytes = 3 * 1_024 * 1_024

    /// A message's "last used" mark is refreshed at most this often, so
    /// reopening a conversation does not write to the database.
    static let touchInterval: TimeInterval = 86_400

    struct Part: Equatable, Sendable {
        var attachmentId: Int64
        /// Normalized (`CIDImageInliner.normalize`).
        var contentId: String
        /// Sanitized (`CIDImageInliner.sanitizeMIME`).
        var mimeType: String
        var data: Data
    }

    /// What identifies one message's cached images: computed outside any
    /// database access (the regex scan and the digest are string work).
    struct Lookup: Equatable, Sendable {
        var messageId: String
        var accountId: String
        var bodyDigest: String
        var references: Set<String>

        init(messageId: String, accountId: String, bodyHTML: String,
             references: Set<String>? = nil) {
            self.messageId = messageId
            self.accountId = accountId
            self.bodyDigest = InlineImageCache.bodyDigest(bodyHTML)
            self.references = references ?? CIDImageInliner.referencedIDs(in: bodyHTML)
        }

        /// Nil for a message whose (hydrated) body references no `cid:` image.
        init?(message: Message) {
            guard let html = message.bodyHTML,
                  CIDImageInliner.containsCIDReferences(html) else { return nil }
            let refs = CIDImageInliner.referencedIDs(in: html)
            guard !refs.isEmpty else { return nil }
            self.init(messageId: message.id, accountId: message.accountId,
                      bodyHTML: html, references: refs)
        }
    }

    /// One message's complete resolve result, waiting to be written.
    struct Pending: Equatable, Sendable {
        var messageId: String
        var accountId: String
        var bodyDigest: String
        var parts: [Part]
    }

    // MARK: Schema

    static func createTable(_ db: Database) throws {
        try db.create(table: tableName) { t in
            t.primaryKey("attachmentId", .integer)
                .references("attachment", onDelete: .cascade)
            t.column("messageId", .text).notNull()
                .references("message", onDelete: .cascade)
            t.column("accountId", .text).notNull().indexed()
                .references("account", onDelete: .cascade)
            t.column("bodyDigest", .text).notNull()
            t.column("contentId", .text).notNull()
            t.column("mimeType", .text).notNull()
            t.column("byteCount", .integer).notNull()
            t.column("lastUsedAt", .double).notNull()
            // Last: the small columns stay in the row's own page, so a "used"
            // mark dirties only that page, not the image's overflow pages.
            t.column("data", .blob).notNull()
        }
        // One covering index for the per-message lookups, the cascade from
        // `message`, the budget sum and the eviction's GROUP BY.
        try db.create(index: "inlineImage_on_messageId_lastUsedAt_byteCount",
                      on: tableName, columns: ["messageId", "lastUsedAt", "byteCount"])
    }

    // MARK: Keys

    /// Content revision of a body: a body that changed no longer matches
    /// the images resolved from it.
    static func bodyDigest(_ html: String) -> String {
        SHA256.hash(data: Data(html.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Raster image types only: SVG (a script grammar) and anything that is
    /// not `image/*` are never stored.
    static func isStorableMIME(_ raw: String) -> Bool {
        let head = raw.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        return head.hasPrefix("image/") && CIDImageInliner.sanitizeMIME(head) == head
    }

    // MARK: Reads

    /// Cached images of one message's current body, keyed by normalized
    /// Content-ID. Only rows of this message and account, resolved from this
    /// very body, whose attachment row still belongs to the message and still
    /// carries that Content-ID.
    static func parts(_ db: Database, _ lookup: Lookup) throws -> [String: Part] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT i.attachmentId, i.contentId, i.mimeType, i.data,
                   a.contentId AS rowContentId
            FROM inlineImage i
            JOIN attachment a ON a.id = i.attachmentId AND a.messageId = i.messageId
            WHERE i.messageId = ? AND i.accountId = ? AND i.bodyDigest = ?
            """, arguments: [lookup.messageId, lookup.accountId, lookup.bodyDigest])
        var out: [String: Part] = [:]
        for row in rows {
            let cid: String = row["contentId"]
            guard let rowCID: String = row["rowContentId"],
                  CIDImageInliner.normalize(rowCID) == cid else { continue }
            out[cid] = Part(attachmentId: row["attachmentId"], contentId: cid,
                            mimeType: row["mimeType"], data: row["data"])
        }
        return out
    }

    /// For each lookup: its cached parts, only when every referenced image is
    /// cached. A partial set is never served: the pane resolves that message
    /// as usual instead.
    static func completeParts(_ db: Database,
                              _ lookups: [Lookup]) throws -> [String: [String: Part]] {
        var out: [String: [String: Part]] = [:]
        for lookup in lookups where !lookup.references.isEmpty {
            let found = try parts(db, lookup)
            guard lookup.references.isSubset(of: Set(found.keys)) else { continue }
            out[lookup.messageId] = found.filter { lookup.references.contains($0.key) }
        }
        return out
    }

    /// Total image bytes stored.
    static func totalBytes(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(byteCount), 0) FROM inlineImage") ?? 0
    }

    /// Of `messageIds`, those with images whose "used" mark is older than
    /// `cutoff`, i.e. the ones a touch would actually change.
    static func staleMessageIds(_ db: Database, _ messageIds: [String],
                                cutoff: Date) throws -> [String] {
        var out: [String] = []
        for chunk in chunks(messageIds) {
            out += try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT messageId FROM inlineImage
                    WHERE messageId IN (\(marks(chunk.count))) AND lastUsedAt < ?
                    """,
                arguments: StatementArguments(chunk)
                    + StatementArguments([cutoff.timeIntervalSinceReferenceDate]))
        }
        return out
    }

    // MARK: Writes

    /// Store one message's complete result, replacing what it had. Nothing
    /// is written unless everything still matches, checked in this
    /// transaction: the message (of that account) and its body as resolved,
    /// and every part's attachment row with its Content-ID and a raster
    /// image type. A message deleted or rewritten while the write waited is
    /// therefore never brought back.
    @discardableResult
    static func store(_ db: Database, _ pending: Pending, now: Date) throws -> Bool {
        guard !pending.parts.isEmpty,
              pending.parts.reduce(0, { $0 + $1.data.count }) <= perMessageBytes,
              try Bool.fetchOne(db, sql: """
                  SELECT 1 FROM message WHERE id = ? AND accountId = ?
                  """, arguments: [pending.messageId, pending.accountId]) == true,
              let html = try String.fetchOne(db, sql: """
                  SELECT bodyHTML FROM message_body WHERE messageId = ?
                  """, arguments: [pending.messageId]),
              bodyDigest(html) == pending.bodyDigest
        else { return false }
        for part in pending.parts {
            guard !part.data.isEmpty,
                  let row = try Row.fetchOne(db, sql: """
                      SELECT contentId, mimeType FROM attachment WHERE id = ? AND messageId = ?
                      """, arguments: [part.attachmentId, pending.messageId]),
                  let rowCID: String = row["contentId"],
                  CIDImageInliner.normalize(rowCID) == part.contentId,
                  let rowMIME: String = row["mimeType"],
                  isStorableMIME(rowMIME),
                  part.mimeType == CIDImageInliner.sanitizeMIME(rowMIME)
            else { return false }
        }
        try forget(db, messageId: pending.messageId)
        let stamp = now.timeIntervalSinceReferenceDate
        for part in pending.parts {
            try db.execute(sql: """
                INSERT INTO inlineImage (attachmentId, messageId, accountId, bodyDigest,
                    contentId, mimeType, byteCount, lastUsedAt, data)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [part.attachmentId, pending.messageId, pending.accountId,
                                 pending.bodyDigest, part.contentId, part.mimeType,
                                 part.data.count, stamp, part.data])
        }
        return true
    }

    /// Marks messages' images as used now (least-recently-used order), only
    /// where the mark is older than `touchInterval`.
    static func touch(_ db: Database, messageIds: [String], now: Date) throws {
        let stamp = now.timeIntervalSinceReferenceDate
        let cutoff = stamp - touchInterval
        for chunk in chunks(messageIds) {
            try db.execute(
                sql: """
                    UPDATE inlineImage SET lastUsedAt = ?
                    WHERE messageId IN (\(marks(chunk.count))) AND lastUsedAt < ?
                    """,
                arguments: StatementArguments([stamp]) + StatementArguments(chunk)
                    + StatementArguments([cutoff]))
        }
    }

    /// Deletes whole messages, least recently used first, until the total is
    /// within `budget`. A real delete: `secure_delete` zeroes the bytes and
    /// the deletion schedules the WAL scrub. Returns the evicted message ids.
    @discardableResult
    static func evict(_ db: Database, budget: Int) throws -> [String] {
        var total = try totalBytes(db)
        guard total > budget else { return [] }
        let groups = try Row.fetchAll(db, sql: """
            SELECT messageId, SUM(byteCount) AS bytes, MAX(lastUsedAt) AS used
            FROM inlineImage GROUP BY messageId
            ORDER BY used ASC, messageId ASC
            """)
        var victims: [String] = []
        for group in groups {
            guard total > budget else { break }
            victims.append(group["messageId"])
            total -= group["bytes"] as Int
        }
        for chunk in chunks(victims) {
            try db.execute(
                sql: "DELETE FROM inlineImage WHERE messageId IN (\(marks(chunk.count)))",
                arguments: StatementArguments(chunk))
        }
        return victims
    }

    static func forget(_ db: Database, messageId: String) throws {
        try db.execute(sql: "DELETE FROM inlineImage WHERE messageId = ?", arguments: [messageId])
    }

    static func forget(_ db: Database, account accountId: String) throws {
        try db.execute(sql: "DELETE FROM inlineImage WHERE accountId = ?", arguments: [accountId])
    }

    /// Rows whose account, message or attachment row is gone. The foreign
    /// keys already cascade; this is the launch sweep's belt and braces.
    static func purgeOrphans(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM inlineImage
            WHERE accountId NOT IN (SELECT id FROM account)
               OR messageId NOT IN (SELECT id FROM message)
               OR attachmentId NOT IN (SELECT id FROM attachment)
            """)
    }

    private static func chunks(_ ids: [String], size: Int = 500) -> [[String]] {
        stride(from: 0, to: ids.count, by: size).map {
            Array(ids[$0..<min($0 + size, ids.count)])
        }
    }

    private static func marks(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}

/// Which resolve results may be written to the persistent cache. The same
/// rule as the in-memory `CIDInlineCachePolicy`: only a complete result, so
/// an image that failed to download is retried on the next open instead of
/// being frozen as a broken image.
enum InlineImageCachePolicy {
    static func shouldStore(references: Set<String>,
                            outcome: CIDPartResolver.Outcome,
                            didRefetch: Bool) -> Bool {
        let parts = outcome.parts
        guard !didRefetch, outcome.allStorable, !references.isEmpty,
              references.isSubset(of: Set(parts.keys)) else { return false }
        let used = parts.filter { references.contains($0.key) }
        guard used.values.allSatisfy({
            !$0.data.isEmpty && $0.attachmentId != CIDPartResolver.unsavedAttachmentId
        }) else { return false }
        return used.values.reduce(0) { $0 + $1.data.count } <= InlineImageCache.perMessageBytes
    }
}

/// Resolves the `cid:` image parts of one message: from the persistent cache
/// first, from Gmail (`fetch`) only for what the cache does not hold.
enum CIDPartResolver {
    struct Outcome: Sendable {
        /// Normalized Content-ID → part, for every reference resolved.
        var parts: [String: InlineImageCache.Part]
        /// How many parts came from `fetch` (an attachment request each).
        var fetchedCount: Int
        /// False when a resolved part is of a type the cache never stores
        /// (SVG, a type that needed relabelling).
        var allStorable: Bool = true
    }

    /// `Part.attachmentId` of a part whose attachment row has no id.
    static let unsavedAttachmentId: Int64 = 0

    /// A cached part is used only for the attachment row it was stored for.
    /// Non-image parts are skipped (never fetched, never stored).
    static func resolve(
        references: Set<String>,
        attachmentsByCID: [String: AttachmentRow],
        cached: [String: InlineImageCache.Part],
        fetch: @Sendable (AttachmentRow) async throws -> Data
    ) async -> Outcome {
        var out = Outcome(parts: [:], fetchedCount: 0)
        for cid in references.sorted() {
            guard let att = attachmentsByCID[cid],
                  att.mimeType.lowercased().hasPrefix("image/") else { continue }
            // A just-parsed row whose write did not land has no id yet: it
            // still resolves, but can neither hit nor be stored.
            let attachmentId = att.id ?? unsavedAttachmentId
            if let hit = cached[cid], att.id != nil, hit.attachmentId == attachmentId,
               !hit.data.isEmpty {
                out.parts[cid] = hit
                continue
            }
            guard !Task.isCancelled else { break }
            out.fetchedCount += 1
            do {
                let data = try await fetch(att)
                guard !data.isEmpty else { continue }
                if !InlineImageCache.isStorableMIME(att.mimeType) { out.allStorable = false }
                out.parts[cid] = InlineImageCache.Part(
                    attachmentId: attachmentId, contentId: cid,
                    mimeType: CIDImageInliner.sanitizeMIME(att.mimeType), data: data)
            } catch {
                // Left unresolved; the other images can still load.
                continue
            }
        }
        return out
    }

    /// The reading pane's resolve (`MailStore.inlineCIDImages`): the
    /// persistent cache first, `fetch` for the rest, then a complete result
    /// is queued for storage, or a cache hit marked as used. `didRefetch`:
    /// the message was just re-fetched, so its rows are new and nothing is
    /// stored for them yet.
    static func resolveUsingCache(
        messageId: String,
        accountId: String,
        bodyHTML: String,
        references: Set<String>,
        attachmentsByCID: [String: AttachmentRow],
        didRefetch: Bool,
        store: InlineImageStore?,
        fetch: @Sendable (AttachmentRow) async throws -> Data
    ) async -> Outcome {
        let lookup = InlineImageCache.Lookup(
            messageId: messageId, accountId: accountId,
            bodyHTML: bodyHTML, references: references)
        var cached: [String: InlineImageCache.Part] = [:]
        if let store, !didRefetch {
            cached = await store.cachedParts(for: lookup)
        }
        let outcome = await resolve(
            references: references, attachmentsByCID: attachmentsByCID,
            cached: cached, fetch: fetch)
        guard let store else { return outcome }
        if outcome.fetchedCount > 0 {
            if InlineImageCachePolicy.shouldStore(
                references: references, outcome: outcome, didRefetch: didRefetch) {
                await store.remember(InlineImageCache.Pending(
                    messageId: messageId, accountId: accountId,
                    bodyDigest: lookup.bodyDigest,
                    parts: Array(outcome.parts.values)))
            }
        } else if !outcome.parts.isEmpty {
            await store.noteUsed([messageId])
        }
        return outcome
    }
}

/// Owns the writes to the persistent inline-image cache: batched, off the
/// main actor, and stopped cleanly at quit.
///
/// Results and "used" marks queue here and are written `flushDelay` after
/// the first of them: one transaction per stored message, then one for the
/// marks and the eviction. Each transaction is atomic, so a quit or crash
/// during a write leaves a message's images whole or absent. A "used" mark
/// younger than `InlineImageCache.touchInterval` writes nothing.
/// `shutDown` (called by the app's termination path before the pool
/// closes) drops what is queued, cancels the pending or running write (GRDB
/// rolls a cancelled transaction back) and awaits it.
actor InlineImageStore {
    private let db: any DatabaseWriter
    private let budget: Int
    private let flushDelayNanoseconds: UInt64
    private let now: @Sendable () -> Date
    private var pendingStores: [String: InlineImageCache.Pending] = [:]
    private var pendingTouches: Set<String> = []
    /// Sleeping until the next batched write.
    private var timerTask: Task<Void, Never>?
    /// The write in flight, if any.
    private var writeTask: Task<Void, Never>?
    private var isClosed = false

    /// Write transactions begun (test observability).
    private(set) var writeTransactionCount = 0
    /// Batches begun and finished (cancelled ones included).
    private(set) var batchesStarted = 0
    private(set) var batchesFinished = 0

    init(db: any DatabaseWriter,
         budget: Int = InlineImageCache.totalBudgetBytes,
         flushDelayNanoseconds: UInt64 = 750_000_000,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db
        self.budget = budget
        self.flushDelayNanoseconds = flushDelayNanoseconds
        self.now = now
    }

    /// Cached images of one message's current body (see
    /// `InlineImageCache.parts`). Empty on any error: a miss, never a failure.
    nonisolated func cachedParts(for lookup: InlineImageCache.Lookup) async
        -> [String: InlineImageCache.Part] {
        (try? await db.read { db in try InlineImageCache.parts(db, lookup) }) ?? [:]
    }

    /// See `InlineImageCache.completeParts`. Empty on any error.
    nonisolated func completeParts(for lookups: [InlineImageCache.Lookup]) async
        -> [String: [String: InlineImageCache.Part]] {
        guard !lookups.isEmpty else { return [:] }
        return (try? await db.read { db in
            try InlineImageCache.completeParts(db, lookups)
        }) ?? [:]
    }

    /// Queue a complete resolve result. The caller checked
    /// `InlineImageCachePolicy`; the write checks again that the message,
    /// body and attachment rows are still the ones it was resolved from.
    func remember(_ pending: InlineImageCache.Pending) {
        guard !isClosed else { return }
        var sorted = pending
        sorted.parts.sort { $0.attachmentId < $1.attachmentId }
        pendingStores[pending.messageId] = sorted
        scheduleFlush()
    }

    /// Mark messages whose images the reading pane just showed. Prefetch
    /// must not call this.
    func noteUsed(_ messageIds: [String]) {
        guard !isClosed, !messageIds.isEmpty else { return }
        pendingTouches.formUnion(messageIds)
        scheduleFlush()
    }

    /// Write what is queued now instead of at the timer.
    func flush() async {
        timerTask?.cancel()
        timerTask = nil
        await write()
    }

    /// Stop for good: queued work is dropped, a pending or running write is
    /// cancelled and awaited. Call before the pool closes.
    func shutDown() async {
        isClosed = true
        pendingStores = [:]
        pendingTouches = []
        let timer = timerTask
        timer?.cancel()
        await timer?.value
        timerTask = nil
        // A write that started meanwhile is cancelled and awaited too.
        while let running = writeTask {
            running.cancel()
            await running.value
            if writeTask == running { writeTask = nil }
        }
    }

    var queuedMessageCount: Int { pendingStores.count }
    var isWriting: Bool { writeTask != nil }

    private func scheduleFlush() {
        guard timerTask == nil, !isClosed else { return }
        let delay = flushDelayNanoseconds
        timerTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await self?.timerFired()
        }
    }

    private func timerFired() async {
        timerTask = nil
        await write()
    }

    private func countTransaction() { writeTransactionCount += 1 }
    private func batchDidFinish() { batchesFinished += 1 }

    /// Everything queued, one transaction per stored message. Writes run
    /// one at a time.
    private func write() async {
        while let running = writeTask {
            await running.value
            if writeTask == running { writeTask = nil }
        }
        guard !isClosed, !pendingStores.isEmpty || !pendingTouches.isEmpty else { return }
        let stores = pendingStores.values.sorted { $0.messageId < $1.messageId }
        let touches = pendingTouches.subtracting(pendingStores.keys).sorted()
        pendingStores = [:]
        pendingTouches = []
        let stamp = now()
        let budget = budget
        let db = db
        batchesStarted += 1
        // A failed or cancelled write rolls back; the results are only a
        // cache, so they are not queued again.
        let task = Task<Void, Never> { [weak self] in
            var stored = false
            for pending in stores {
                guard !Task.isCancelled else { break }
                await self?.countTransaction()
                let ok = (try? await db.write { db in
                    try InlineImageCache.store(db, pending, now: stamp)
                }) ?? false
                stored = stored || ok
            }
            var stale: [String] = []
            if !touches.isEmpty, !Task.isCancelled {
                let cutoff = stamp.addingTimeInterval(-InlineImageCache.touchInterval)
                stale = (try? await db.read { db in
                    try InlineImageCache.staleMessageIds(db, touches, cutoff: cutoff)
                }) ?? []
            }
            if (stored || !stale.isEmpty), !Task.isCancelled {
                await self?.countTransaction()
                let marks = stale
                _ = try? await db.write { db in
                    try InlineImageCache.touch(db, messageIds: marks, now: stamp)
                    try InlineImageCache.evict(db, budget: budget)
                }
            }
            await self?.batchDidFinish()
        }
        writeTask = task
        await task.value
        if writeTask == task { writeTask = nil }
        if !pendingStores.isEmpty || !pendingTouches.isEmpty { scheduleFlush() }
    }
}
