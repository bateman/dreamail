import Foundation
import GRDB

/// Precomputed reading-pane body work for one message.
///
/// Quote-trail scans and HTML document assembly are whole-body string work —
/// doing them on the main actor at first paint stalls keyboard browse. The
/// repository actor builds these once per `ThreadContentRevision` (and
/// fontScale) so `MessageCard` / `HTMLBodyView` only hand ready strings to
/// WebKit.
///
/// Dark/light appearance is handled inside the injected CSS via
/// `prefers-color-scheme`, so one assembled document covers both appearances.
/// Font scale and remote-image CSP do change the string; documents are keyed
/// for both image policies at the scale used when the payload was built.
struct MessageHTMLPrep: Equatable, Sendable {
    var textHead: String?
    var htmlHead: String?
    var hasQuotedTrail: Bool
    var htmlBytes: Int
    var htmlHeadBytes: Int
    /// Assembled documents for the fontScale recorded on `documents`.
    var documents: MessageHTMLDocuments?

    static let empty = MessageHTMLPrep(
        textHead: nil, htmlHead: nil, hasQuotedTrail: false,
        htmlBytes: 0, htmlHeadBytes: 0, documents: nil)
}

/// Memo for the on-demand allowed-CSP documents.
///
/// Reference type so the assembled string survives struct copies: `document`
/// is read from `MessageCard`'s SwiftUI body, which re-evaluates on every
/// height change, and re-assembling a multi-hundred-KB body there would stall
/// the main actor. Locked because payload copies cross the repository actor
/// and the off-main assembly in `HTMLBodyView.Coordinator`.
///
/// `build` runs *outside* the lock so `peek` — called from the main actor —
/// never waits behind a background assembly. Two racing misses may both
/// build; the first stored result wins and both callers see equal strings.
private final class AllowedDocumentMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: [Bool: String?] = [:]
    #if DEBUG
    /// Times `build` actually ran (misses). Pins "assembled at most once per
    /// key" in tests — string-equality checks can't tell a memo hit from a
    /// per-access rebuild.
    private var missCount = 0

    var debugMissCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return missCount
    }
    #endif

    /// Non-building lookup: `.some(value)` when this key was memoized
    /// (value itself may be nil for over-budget sources), `.none` on a miss.
    func peek(authored: Bool) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        return cached[authored]
    }

    /// `build` runs once per key for sequential callers; nil results are
    /// memoized too.
    func value(authored: Bool, build: () -> String?) -> String? {
        if let hit = peek(authored: authored) { return hit }
        let made = build()
        lock.lock()
        defer { lock.unlock() }
        if let raced = cached[authored] { return raced }
        #if DEBUG
        missCount += 1
        #endif
        cached[authored] = made
        return made
    }
}

/// Pre-assembled HTML for (authored|full) × (blocked|allowed).
///
/// Blocked CSP variants are built eagerly (Spam, Ask, non-VIP mail and
/// neighbour pre-render use them; the default Always policy mostly does not
/// — measured later, unchanged here). Allowed
/// variants are assembled on first request and memoized, so the detail LRU
/// does not retain four full copies of every body (~2 MB each) while a thread
/// that does allow images still pays the assembly only once.
///
/// The main actor reads through `readyDocument`, which never assembles: an
/// allowed variant that is not memoized yet comes back nil, and
/// `HTMLBodyView` builds it off-main via `document(authored:allowRemoteImages:)`
/// — filling the shared memo so the next mount is a plain lookup.
struct MessageHTMLDocuments: Equatable, Sendable {
    var fontScale: Double
    var authoredBlocked: String?
    var fullBlocked: String?
    /// Source fragments for on-demand allowed assembly (not expanded docs).
    fileprivate var authoredSource: String?
    fileprivate var fullSource: String?
    /// Largest source the allowed variants will assemble. Repository docs use
    /// the auto-render budget; CID-inlined docs lift it, because `data:` image
    /// payload inflates the string without adding markup for WebKit to parse
    /// and the card already gated on the pre-inline size.
    fileprivate var sourceByteBudget: Int = HTMLBodyRenderPolicy.maximumAutomaticBytes
    /// Excluded from `==`: pure derived state, shared across struct copies.
    private let allowedMemo = AllowedDocumentMemo()

    /// Allowed variant for the authored head, assembled once on first request.
    /// Whole-document string work — call off the main actor.
    var authoredAllowed: String? {
        allowedMemo.value(authored: true) {
            guard let source = authoredSource, !source.isEmpty else { return nil }
            return Self.assemble(source, allowRemoteImages: true,
                                 fontScale: fontScale, byteBudget: sourceByteBudget)
        }
    }

    /// Allowed variant for the full body, assembled once on first request.
    /// Whole-document string work — call off the main actor.
    var fullAllowed: String? {
        allowedMemo.value(authored: false) {
            guard let source = fullSource, !source.isEmpty else { return nil }
            return Self.assemble(source, allowRemoteImages: true,
                                 fontScale: fontScale, byteBudget: sourceByteBudget)
        }
    }

    /// Main-actor-safe lookup: blocked variants, or an allowed variant only
    /// when it is already memoized. Never assembles. nil means "not ready
    /// here" — the caller hands the build to a background task.
    func readyDocument(authored: Bool, allowRemoteImages: Bool) -> String? {
        guard allowRemoteImages else {
            return authored ? authoredBlocked : fullBlocked
        }
        return allowedMemo.peek(authored: authored) ?? nil
    }

    #if DEBUG
    /// Test-only: how many allowed-variant builds the shared memo has run.
    var debugAllowedBuildCount: Int { allowedMemo.debugMissCount }
    #endif

    func document(authored: Bool, allowRemoteImages: Bool) -> String? {
        switch (authored, allowRemoteImages) {
        case (true, false): return authoredBlocked
        case (true, true): return authoredAllowed
        case (false, false): return fullBlocked
        case (false, true): return fullAllowed
        }
    }

    /// Documents are replaced wholesale (never field-mutated), so equal
    /// sources + scale means equal output; the memo is derived state.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fontScale == rhs.fontScale
            && lhs.authoredBlocked == rhs.authoredBlocked
            && lhs.fullBlocked == rhs.fullBlocked
            && lhs.authoredSource == rhs.authoredSource
            && lhs.fullSource == rhs.fullSource
            && lhs.sourceByteBudget == rhs.sourceByteBudget
    }

    private static func assemble(_ source: String, allowRemoteImages: Bool,
                                 fontScale: Double, byteBudget: Int) -> String? {
        guard source.utf8.count <= byteBudget else { return nil }
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: fontScale)
        let csp = HTMLBodyCSP.metaTag(allowRemoteImages: allowRemoteImages)
        let doc = HTMLBodyDocument.assemble(html: source, cspMeta: csp, styleCSS: css)
        return doc.isEmpty ? nil : doc
    }
}

/// Pure builder for quote-trail + document assembly (hostless-testable).
enum MessageHTMLPrepBuilder {
    /// Scan the body for a collapsible quoted trail and assemble the HTML
    /// documents WebKit will load. Preserves `HTMLBodyRenderPolicy` 2 MB
    /// guards: oversized bodies only get a bounded quote scan, and auto-render
    /// documents are still subject to the same byte budget at paint time.
    static func prep(bodyText: String, bodyHTML: String?,
                     fontScale: Double) -> MessageHTMLPrep {
        let fullHTMLBytes = bodyHTML?.utf8.count ?? 0
        guard fullHTMLBytes > 0 || !bodyText.isEmpty else { return .empty }

        let detectedHTMLHead: String? = {
            guard let html = bodyHTML, !html.isEmpty else { return nil }
            if fullHTMLBytes <= HTMLBodyRenderPolicy.maximumAutomaticBytes {
                return QuotedReply.authoredHTMLHead(html)
            }
            return QuotedReply.authoredHTMLHead(
                html,
                scanCharacterLimit: HTMLBodyRenderPolicy.oversizedQuoteScanCharacterLimit)
        }()

        let textHead: String?
        let htmlHead: String?
        let hasQuotedTrail: Bool
        if let head = detectedHTMLHead {
            textHead = nil
            htmlHead = head
            hasQuotedTrail = true
        } else if fullHTMLBytes <= HTMLBodyRenderPolicy.maximumAutomaticBytes,
                  let head = QuotedReply.splitText(bodyText)?.head {
            textHead = head
            htmlHead = nil
            hasQuotedTrail = true
        } else {
            textHead = nil
            htmlHead = nil
            hasQuotedTrail = false
        }
        let htmlHeadBytes = htmlHead?.utf8.count ?? 0

        let documents: MessageHTMLDocuments?
        if let html = bodyHTML, !html.isEmpty {
            documents = assembleDocuments(
                fullHTML: html,
                htmlHead: htmlHead,
                fontScale: fontScale)
        } else {
            documents = nil
        }

        return MessageHTMLPrep(
            textHead: textHead,
            htmlHead: htmlHead,
            hasQuotedTrail: hasQuotedTrail,
            htmlBytes: fullHTMLBytes,
            htmlHeadBytes: htmlHeadBytes,
            documents: documents)
    }

    /// Prep for a body whose `cid:` images were rewritten to `data:` URIs.
    ///
    /// The inlined string embeds base64 image bytes (often megabytes), so the
    /// quote scan and document assembly here must run off the main actor —
    /// `MessageCard.init` used to redo the scan on every parent body pass.
    /// Mirrors that old in-card logic exactly:
    /// - The quote-scan cap keys on the *inlined* size (that is what gets
    ///   scanned).
    /// - `htmlBytes` is the *pre-inline* size: data: URI growth is image
    ///   payload WebKit handles fine, and a message that rendered
    ///   automatically before inlining must not flip into the approval
    ///   placeholder because its images resolved.
    /// - No plain-text head: the CID path always renders HTML.
    ///
    /// Documents are assembled only for variants the card will auto-render
    /// (rendered bytes within budget); the explicit-approval path builds its
    /// document off-main in `HTMLBodyView` instead.
    static func cidInlinedPrep(inlinedHTML: String, preInlineBytes: Int,
                               fontScale: Double) -> MessageHTMLPrep {
        guard !inlinedHTML.isEmpty else { return .empty }
        let fullBytes = inlinedHTML.utf8.count
        let budget = HTMLBodyRenderPolicy.maximumAutomaticBytes
        let htmlHead: String?
        if fullBytes <= budget {
            htmlHead = QuotedReply.authoredHTMLHead(inlinedHTML)
        } else {
            htmlHead = QuotedReply.authoredHTMLHead(
                inlinedHTML,
                scanCharacterLimit: HTMLBodyRenderPolicy.oversizedQuoteScanCharacterLimit)
        }
        let htmlBytes = preInlineBytes
        let htmlHeadBytes = min(htmlHead?.utf8.count ?? 0, htmlBytes)

        let css = HTMLBodyDarkMode.injectedCSS(fontScale: fontScale)
        let cspBlocked = HTMLBodyCSP.metaTag(allowRemoteImages: false)
        func assembleBlocked(_ source: String) -> String? {
            let doc = HTMLBodyDocument.assemble(
                html: source, cspMeta: cspBlocked, styleCSS: css)
            return doc.isEmpty ? nil : doc
        }
        var authoredBlocked: String?
        var authoredSource: String?
        if let head = htmlHead, !head.isEmpty, htmlHeadBytes <= budget {
            authoredBlocked = assembleBlocked(head)
            authoredSource = authoredBlocked == nil ? nil : head
        }
        var fullBlocked: String?
        var fullSource: String?
        if htmlBytes <= budget {
            fullBlocked = assembleBlocked(inlinedHTML)
            fullSource = fullBlocked == nil ? nil : inlinedHTML
        }
        let documents = MessageHTMLDocuments(
            fontScale: fontScale,
            authoredBlocked: authoredBlocked,
            fullBlocked: fullBlocked,
            authoredSource: authoredSource,
            fullSource: fullSource,
            sourceByteBudget: .max)

        return MessageHTMLPrep(
            textHead: nil,
            htmlHead: htmlHead,
            hasQuotedTrail: htmlHead != nil,
            htmlBytes: htmlBytes,
            htmlHeadBytes: htmlHeadBytes,
            documents: documents)
    }

    /// Rebuild only the assembled documents for a new font scale, keeping the
    /// already-scanned quote trail.
    static func reassembleDocuments(_ prep: MessageHTMLPrep,
                                    fullHTML: String?,
                                    fontScale: Double) -> MessageHTMLPrep {
        guard let html = fullHTML, !html.isEmpty else {
            var copy = prep
            copy.documents = nil
            return copy
        }
        var copy = prep
        copy.documents = assembleDocuments(
            fullHTML: html,
            htmlHead: prep.htmlHead,
            fontScale: fontScale)
        return copy
    }

    private static func assembleDocuments(fullHTML: String,
                                          htmlHead: String?,
                                          fontScale: Double) -> MessageHTMLDocuments {
        // Only blocked CSP variants are expanded eagerly. Allowed variants are
        // produced on demand from the retained sources. Under the default
        // Always policy most opens want the allowed one; the blocked one
        // still serves Spam, Ask, non-VIP mail and neighbour pre-render.
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: fontScale)
        let cspBlocked = HTMLBodyCSP.metaTag(allowRemoteImages: false)

        func assembleBlocked(_ source: String) -> String? {
            // Cap automatic assembly the same way render does — multi-megabyte
            // bodies stay behind the explicit-load placeholder and never get
            // a prebuilt document that would thrash memory in the LRU.
            guard source.utf8.count <= HTMLBodyRenderPolicy.maximumAutomaticBytes
            else { return nil }
            let doc = HTMLBodyDocument.assemble(
                html: source, cspMeta: cspBlocked, styleCSS: css)
            return doc.isEmpty ? nil : doc
        }

        let authoredSource: String?
        let authoredBlocked: String?
        if let head = htmlHead, !head.isEmpty {
            authoredSource = head
            authoredBlocked = assembleBlocked(head)
        } else {
            authoredSource = nil
            authoredBlocked = nil
        }

        let fullBlocked = assembleBlocked(fullHTML)
        // Retain full source only when a blocked doc was produced (under budget).
        let fullSource: String? = fullBlocked == nil ? nil : fullHTML
        // Drop authored source when blocked assembly was skipped (over budget).
        let retainedAuthoredSource: String? = authoredBlocked == nil ? nil : authoredSource

        return MessageHTMLDocuments(
            fontScale: fontScale,
            authoredBlocked: authoredBlocked,
            fullBlocked: fullBlocked,
            authoredSource: retainedAuthoredSource,
            fullSource: fullSource)
    }
}

/// Everything the reading pane needs for its first useful frame.
///
/// Headers, the initially expanded body, draft bodies, and attachments load in
/// one database snapshot. Keeping this payload together avoids a main-thread
/// query per message/card and gives neighbor prefetch a reusable result.
struct ThreadDetailPayload: Equatable {
    var messages: [Message]
    var attachmentsByMessageId: [String: [AttachmentRow]]
    /// Precomputed quote trails + assembled HTML, keyed by message id.
    var bodyPrepByMessageId: [String: MessageHTMLPrep]
    /// Bodies whose `cid:` images were already resolved this session, keyed
    /// by message id. Filled after the first open downloads the parts, so a
    /// re-open paints the images in its first frame instead of downloading
    /// every part from Gmail again and loading the body a second time.
    /// Memory only: it lives and dies with this payload's cache entry.
    var cidInlineByMessageId: [String: CIDInlinedBody] = [:]

    func suppressingDrafts(_ suppressedIds: Set<String>) -> ThreadDetailPayload {
        guard !suppressedIds.isEmpty else { return self }
        let visible = messages.filter { !suppressedIds.contains($0.id) }
        let visibleIds = Set(visible.map(\.id))
        return ThreadDetailPayload(
            messages: visible,
            attachmentsByMessageId: attachmentsByMessageId.filter {
                visibleIds.contains($0.key)
            },
            bodyPrepByMessageId: bodyPrepByMessageId.filter {
                visibleIds.contains($0.key)
            },
            cidInlineByMessageId: cidInlineByMessageId.filter {
                visibleIds.contains($0.key)
            })
    }
}

/// A body with its `cid:` images rewritten to `data:` URIs, plus the prep
/// built from it.
///
/// No attachment rows: only results that needed no Gmail re-fetch are
/// remembered (`CIDInlineCachePolicy`), and those leave the rows exactly as
/// the payload already carries them.
struct CIDInlinedBody: Equatable, Sendable {
    var html: String
    var prep: MessageHTMLPrep

    /// Font scale the prep's documents were assembled at, when any.
    var fontScale: Double? { prep.documents?.fontScale }
}

/// Which resolved `cid:` bodies are worth keeping in memory.
enum CIDInlineCachePolicy {
    /// Above this the body re-downloads its images on the next open, as
    /// before. Inlined images are base64 in the HTML, so a few large photos
    /// would otherwise pin tens of megabytes per cached conversation.
    static let maximumBytes = 4 * 1_024 * 1_024

    /// Remember only a complete, bounded result for the current scale:
    /// - nothing left unresolved (a part that failed to download must be
    ///   retried on the next open, not frozen as a broken image);
    /// - within `maximumBytes`;
    /// - built at `fontScale`.
    static func shouldRemember(_ body: CIDInlinedBody, fontScale: Double) -> Bool {
        guard !CIDImageInliner.containsCIDReferences(body.html),
              body.html.utf8.count <= maximumBytes else { return false }
        if let scale = body.fontScale, abs(scale - fontScale) > 0.001 { return false }
        return true
    }
}

/// How a reading pane seeds its session `cid:` state from a payload.
///
/// Every id returned in `resolvedIds` is marked as already attempted, which
/// is what keeps `resolveCIDImagesIfNeeded` from going to the network.
enum CIDInlineSeed {
    struct Seed: Equatable {
        var htmlById: [String: String] = [:]
        var prepById: [String: MessageHTMLPrep] = [:]
        var resolvedIds: Set<String> = []

        /// Mirrors the guard at the top of `resolveCIDImagesIfNeeded`.
        func needsResolve(_ id: String, attempted: Set<String>) -> Bool {
            !attempted.union(resolvedIds).contains(id)
        }
    }

    /// Bodies built at another font scale are left out: the pane resolves
    /// those again rather than mount documents at the wrong size.
    static func seed(from payload: ThreadDetailPayload, fontScale: Double) -> Seed {
        var seed = Seed()
        let present = Set(payload.messages.map(\.id))
        for (id, body) in payload.cidInlineByMessageId where present.contains(id) {
            if let scale = body.fontScale, abs(scale - fontScale) > 0.001 { continue }
            seed.htmlById[id] = body.html
            seed.prepById[id] = body.prep
            seed.resolvedIds.insert(id)
        }
        return seed
    }
}

/// Small deterministic LRU used by the actor below. Split out so eviction
/// behavior is hostless-testable without constructing a DatabasePool.
struct ThreadDetailLRU<Value> {
    let capacity: Int
    private(set) var values: [String: Value] = [:]
    private(set) var order: [String] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func value(for key: String) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    mutating func insert(_ value: Value, for key: String) {
        values[key] = value
        touch(key)
        while order.count > capacity, let evicted = order.first {
            order.removeFirst()
            values.removeValue(forKey: evicted)
        }
    }

    mutating func removeValue(for key: String) {
        values.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    mutating func removeAll() {
        values.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// Which cached payloads a content change made stale, by the revisions in
/// force after it.
enum ThreadContentStaleness: Equatable, Sendable {
    /// These threads moved to these revisions.
    case threads([String: ThreadContentRevision])
    /// The epoch moved to this value; every older entry is stale.
    case before(epoch: Int)
}

struct ThreadDetailLoad {
    let payload: ThreadDetailPayload
    let cacheHit: Bool
}

struct MessageBodyLoad {
    let message: Message
    let prep: MessageHTMLPrep
}

struct ThreadDetailCacheEntry: Equatable {
    var revision: ThreadContentRevision
    var fontScale: Double
    var payload: ThreadDetailPayload
}

/// Off-main reading-pane repository with a bounded, real neighbor cache.
///
/// The previous prefetch path decoded rows and discarded them. This actor
/// retains ten payloads (current + nearby navigation / re-open) and serializes
/// cache ownership without putting SQLCipher reads on MainActor. Quote-trail
/// scans and HTML document assembly also run here so the main actor only
/// mounts ready strings into WebKit.
actor ThreadDetailRepository {
    private let db: DatabasePool
    private var cache = ThreadDetailLRU<ThreadDetailCacheEntry>(capacity: 10)
    /// Newest revisions `discardStale` has seen. A read that started before
    /// a change (a delete among them) and finishes after it must not put
    /// its stale payload back in memory. Locals reset with each epoch, so
    /// the map is bounded the same way `ThreadContentRevisions` is.
    private var knownEpoch = 0
    private var knownLocals: [String: Int] = [:]

    init(db: DatabasePool) {
        self.db = db
    }

    /// The requested `revision` is the sole validity test — there is no
    /// force-reload escape hatch, because one would silently reintroduce the
    /// blanket invalidation this scoping exists to remove.
    func payload(threadId: String, suppressingDrafts suppressedIds: Set<String>,
                 revision: ThreadContentRevision,
                 fontScale: Double = 1.0) -> ThreadDetailLoad {
        if let cached = cache.value(for: threadId),
           cached.revision == revision {
            var payload = cached.payload
            if abs(cached.fontScale - fontScale) > 0.001 {
                payload = Self.reassemblePayloadDocuments(payload, fontScale: fontScale)
                cache.insert(
                    ThreadDetailCacheEntry(
                        revision: revision,
                        fontScale: fontScale,
                        payload: payload),
                    for: threadId)
            }
            return ThreadDetailLoad(
                payload: payload.suppressingDrafts(suppressedIds),
                cacheHit: true)
        }

        // Hold the SQLCipher reader only for row fetch. Quote scans and HTML
        // document assembly are pure string work and must not pin a connection.
        var loaded = (try? db.read { db in
            try Self.fetchPayload(threadId: threadId, db: db)
        }) ?? ThreadDetailPayload(
            messages: [], attachmentsByMessageId: [:], bodyPrepByMessageId: [:])
        loaded.bodyPrepByMessageId = Self.buildBodyPrep(
            messages: loaded.messages, fontScale: fontScale)
        if !isSuperseded(revision, threadId: threadId) {
            cache.insert(
                ThreadDetailCacheEntry(
                    revision: revision,
                    fontScale: fontScale,
                    payload: loaded),
                for: threadId)
        }
        return ThreadDetailLoad(
            payload: loaded.suppressingDrafts(suppressedIds),
            cacheHit: false)
    }

    func messageBody(id: String, fontScale: Double = 1.0) -> MessageBodyLoad? {
        guard let loaded: Message = try? db.read({ db in
            guard var message = try Message.fetchOne(db, key: id) else { return nil }
            if let body = try MessageBody.fetchOne(db, key: id) {
                message.bodyText = body.bodyText
                message.bodyHTML = body.bodyHTML
            }
            return message
        }) else { return nil }

        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: loaded.bodyText,
            bodyHTML: loaded.bodyHTML,
            fontScale: fontScale)

        if var entry = cache.value(for: loaded.threadId),
           let idx = entry.payload.messages.firstIndex(where: { $0.id == id }) {
            entry.payload.messages[idx] = loaded
            entry.payload.bodyPrepByMessageId[id] = prep
            // Leave entry.fontScale alone: only this one prep was built at
            // the requested scale. Stamping the entry would make a later
            // payload() cache hit skip reassembly for the sibling messages
            // whose documents still carry the old scale.
            cache.insert(entry, for: loaded.threadId)
        }
        return MessageBodyLoad(message: loaded, prep: prep)
    }

    /// Drop a cached thread payload (e.g. after a full re-fetch rewrote
    /// attachment Content-IDs). Safe no-op when the thread was never cached.
    func drop(threadId: String) {
        cache.removeValue(for: threadId)
    }

    /// Release every payload a content change made unreachable.
    ///
    /// The revision test already keeps a stale entry from being *served*;
    /// this makes it leave memory too, so a deleted message's decoded body,
    /// assembled HTML and resolved images do not linger until ten more
    /// conversations push them out ("deleted means gone").
    ///
    /// Takes the revisions *after* the change, and drops only entries built
    /// under an older one: this runs in a task, so a reload for the new
    /// revision may already have landed and must stay.
    func discardStale(_ stale: ThreadContentStaleness) {
        switch stale {
        case .threads(let current):
            for (id, revision) in current {
                noteKnown(revision, threadId: id)
                if cache.values[id].map({ $0.revision != revision }) ?? false {
                    cache.removeValue(for: id)
                }
            }
        case .before(let epoch):
            if epoch > knownEpoch {
                knownEpoch = epoch
                knownLocals.removeAll(keepingCapacity: true)
            }
            for (id, entry) in cache.values where entry.revision.epoch != epoch {
                cache.removeValue(for: id)
            }
        }
    }

    private func noteKnown(_ revision: ThreadContentRevision, threadId: String) {
        if revision.epoch > knownEpoch {
            knownEpoch = revision.epoch
            knownLocals.removeAll(keepingCapacity: true)
        }
        if revision.epoch == knownEpoch {
            knownLocals[threadId] = max(knownLocals[threadId] ?? 0, revision.local)
        }
    }

    /// True when a newer revision of this thread is already known.
    private func isSuperseded(_ revision: ThreadContentRevision,
                              threadId: String) -> Bool {
        revision.epoch < knownEpoch
            || (revision.epoch == knownEpoch
                && revision.local < (knownLocals[threadId] ?? 0))
    }

    /// Remember a resolved `cid:` body on the cached payload it belongs to.
    ///
    /// Stored only when the entry is still the one for `revision` and
    /// `fontScale`; otherwise the result is dropped (the pane will resolve
    /// again on the next open). Never creates an entry of its own, so
    /// eviction and invalidation of the payload take this with it.
    @discardableResult
    func rememberCIDInline(_ body: CIDInlinedBody, messageId: String,
                           threadId: String, revision: ThreadContentRevision,
                           fontScale: Double) -> Bool {
        guard CIDInlineCachePolicy.shouldRemember(body, fontScale: fontScale),
              var entry = cache.values[threadId],
              entry.revision == revision,
              abs(entry.fontScale - fontScale) < 0.001,
              entry.payload.messages.contains(where: { $0.id == messageId })
        else { return false }
        entry.payload.cidInlineByMessageId[messageId] = body
        cache.insert(entry, for: threadId)
        return true
    }

    /// Thread ids with a payload in memory (test observability).
    func cachedThreadIds() -> Set<String> {
        Set(cache.values.keys)
    }

    /// Drop every cached payload (system memory pressure). Each entry holds
    /// a whole conversation's decoded bodies and assembled HTML documents.
    func removeAll() {
        cache.removeAll()
    }

    /// Fetch messages, hydrated bodies, and attachments only. Callers must run
    /// `buildBodyPrep` after the read transaction returns.
    nonisolated static func fetchPayload(threadId: String,
                                         db: Database) throws -> ThreadDetailPayload {
        var messages = try Message.fetchAll(
            db,
            sql: """
                SELECT id, accountId, gmailId, threadId, fromHeader, toHeader, ccHeader,
                       bccHeader, subject, date, snippet,
                       '' AS bodyText, NULL AS bodyHTML,
                       messageIdHeader, referencesHeader, labelIds, isUnread, hasAttachment,
                       senderAuth, replyToHeader, deliveredTo,
                       listUnsubscribe, listUnsubscribePost
                FROM message
                WHERE threadId = ?
                ORDER BY date
                """,
            arguments: [threadId])

        // First frame expands the newest sent message. Live draft cards also
        // need their previews immediately, so hydrate exactly those bodies.
        var hydrateIds = Set(
            messages.filter { Self.isLiveDraft($0.labelIds) }.map(\.id))
        if let newestSent = messages.last(where: {
            !Self.hasDraftLabel($0.labelIds)
        }) {
            hydrateIds.insert(newestSent.id)
        }
        if !hydrateIds.isEmpty {
            let bodies = try MessageBody
                .filter(hydrateIds.contains(Column("messageId")))
                .fetchAll(db)
            let byId = Dictionary(uniqueKeysWithValues: bodies.map { ($0.messageId, $0) })
            for idx in messages.indices {
                if let body = byId[messages[idx].id] {
                    messages[idx].bodyText = body.bodyText
                    messages[idx].bodyHTML = body.bodyHTML
                }
            }
        }

        let messageIds = messages.map(\.id)
        let attachments: [AttachmentRow]
        if messageIds.isEmpty {
            attachments = []
        } else {
            attachments = try AttachmentRow
                .filter(messageIds.contains(Column("messageId")))
                .order(Column("id"))
                .fetchAll(db)
        }

        return ThreadDetailPayload(
            messages: messages,
            attachmentsByMessageId: Dictionary(grouping: attachments, by: \.messageId),
            bodyPrepByMessageId: [:])
    }

    /// Quote-trail scan + document assembly — pure string work, no DB.
    nonisolated static func buildBodyPrep(
        messages: [Message],
        fontScale: Double
    ) -> [String: MessageHTMLPrep] {
        var bodyPrep: [String: MessageHTMLPrep] = [:]
        bodyPrep.reserveCapacity(messages.count)
        for message in messages {
            // Skip empty header-only rows — prep is filled when the body loads.
            let hasBody = !(message.bodyText.isEmpty && (message.bodyHTML ?? "").isEmpty)
            guard hasBody else { continue }
            bodyPrep[message.id] = MessageHTMLPrepBuilder.prep(
                bodyText: message.bodyText,
                bodyHTML: message.bodyHTML,
                fontScale: fontScale)
        }
        return bodyPrep
    }

    private nonisolated static func reassemblePayloadDocuments(
        _ payload: ThreadDetailPayload,
        fontScale: Double
    ) -> ThreadDetailPayload {
        var copy = payload
        // CID preps carry the old scale; the pane re-resolves them on open.
        copy.cidInlineByMessageId = [:]
        for message in payload.messages {
            guard var prep = copy.bodyPrepByMessageId[message.id] else { continue }
            prep = MessageHTMLPrepBuilder.reassembleDocuments(
                prep, fullHTML: message.bodyHTML, fontScale: fontScale)
            copy.bodyPrepByMessageId[message.id] = prep
        }
        return copy
    }

    private nonisolated static func hasDraftLabel(_ labelIds: String) -> Bool {
        labelIds.split(whereSeparator: \.isWhitespace).contains { $0 == "DRAFT" }
    }

    private nonisolated static func isLiveDraft(_ labelIds: String) -> Bool {
        let labs = Set(labelIds.split(whereSeparator: \.isWhitespace).map(String.init))
        return labs.contains("DRAFT") && !labs.contains("TRASH")
    }
}
