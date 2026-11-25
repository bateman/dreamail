import XCTest
import GRDB

final class ThreadDetailCacheTests: XCTestCase {
    func testLRUEvictsLeastRecentlyUsed() {
        var cache = ThreadDetailLRU<Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        XCTAssertEqual(cache.value(for: "a"), 1) // a is now most recent

        cache.insert(3, for: "c")

        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertEqual(cache.value(for: "c"), 3)
    }

    func testLRUReplacementDoesNotDuplicateOrder() {
        var cache = ThreadDetailLRU<Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "a")
        cache.insert(3, for: "b")

        XCTAssertEqual(cache.order, ["a", "b"])
        XCTAssertEqual(cache.value(for: "a"), 2)
    }

    func testDraftSuppressionDropsMessagesAndAttachmentsTogether() {
        let sent = fixtureMessage(id: "sent", labels: "INBOX")
        let draft = fixtureMessage(id: "draft", labels: "DRAFT")
        let payload = ThreadDetailPayload(
            messages: [sent, draft],
            attachmentsByMessageId: [
                "sent": [fixtureAttachment(messageId: "sent")],
                "draft": [fixtureAttachment(messageId: "draft")],
            ],
            bodyPrepByMessageId: [
                "sent": .empty,
                "draft": .empty,
            ])

        let visible = payload.suppressingDrafts(["draft"])

        XCTAssertEqual(visible.messages.map(\.id), ["sent"])
        XCTAssertEqual(Set(visible.attachmentsByMessageId.keys), ["sent"])
        XCTAssertEqual(Set(visible.bodyPrepByMessageId.keys), ["sent"])
    }

    func testMessageHTMLPrepDetectsQuotedTrailAndAssemblesDocuments() throws {
        let html = """
        <div>New reply</div>
        <div class="gmail_quote">On Mon, Alice wrote:<br>Earlier</div>
        """
        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: "New reply\n\nOn Mon, Alice wrote:\n> Earlier",
            bodyHTML: html,
            fontScale: 1.0)

        XCTAssertTrue(prep.hasQuotedTrail)
        XCTAssertNotNil(prep.htmlHead)
        XCTAssertFalse(prep.htmlHead?.contains("gmail_quote") ?? true)
        XCTAssertEqual(prep.htmlBytes, html.utf8.count)
        let docs = try XCTUnwrap(prep.documents)
        XCTAssertEqual(docs.fontScale, 1.0)
        // Blocked variants are eager; allowed are on-demand from retained sources.
        XCTAssertNotNil(docs.authoredBlocked)
        XCTAssertNotNil(docs.fullBlocked)
        XCTAssertNotNil(docs.document(authored: true, allowRemoteImages: true))
        XCTAssertNotNil(docs.document(authored: false, allowRemoteImages: true))
        // Assembled documents inject CSP + CSS.
        XCTAssertTrue(docs.fullBlocked?.contains("Content-Security-Policy") ?? false)
        XCTAssertTrue(docs.authoredBlocked?.contains("New reply") ?? false)
        XCTAssertFalse(docs.authoredBlocked?.contains("gmail_quote") ?? true)
        // Allowed CSP differs from blocked (remote img-src).
        let allowed = try XCTUnwrap(docs.document(authored: false, allowRemoteImages: true))
        XCTAssertTrue(allowed.contains("img-src data: cid: https:"))
        XCTAssertFalse(docs.fullBlocked?.contains("img-src data: cid: https:") ?? true)
    }

    func testMessageHTMLPrepSkipsAssemblyAboveAutomaticByteBudget() {
        // Oversized body: trail scan is bounded; no auto-render documents.
        let big = String(repeating: "x", count: HTMLBodyRenderPolicy.maximumAutomaticBytes + 1)
        let html = "<div>\(big)</div>"
        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: "", bodyHTML: html, fontScale: 1.0)
        XCTAssertEqual(prep.htmlBytes, html.utf8.count)
        // Full assembly is skipped — nothing under the 2 MB auto budget.
        XCTAssertNil(prep.documents?.fullBlocked)
        XCTAssertNil(prep.documents?.document(authored: false, allowRemoteImages: true))
    }

    func testMessageHTMLPrepReassembleKeepsTrail() {
        let html = """
        <div>Hi</div>
        <div class="gmail_quote">quoted</div>
        """
        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: "Hi", bodyHTML: html, fontScale: 1.0)
        let rebuilt = MessageHTMLPrepBuilder.reassembleDocuments(
            prep, fullHTML: html, fontScale: 1.2)
        XCTAssertEqual(rebuilt.htmlHead, prep.htmlHead)
        XCTAssertEqual(rebuilt.hasQuotedTrail, prep.hasQuotedTrail)
        XCTAssertEqual(rebuilt.documents?.fontScale, 1.2)
        XCTAssertNotNil(rebuilt.documents?.fullBlocked)
    }

    func testMessageHTMLDocumentsAllowedVariantsAreLazy() throws {
        let html = "<p>Body with tracker <img src=\"https://t.example/p.gif\"></p>"
        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: "Body", bodyHTML: html, fontScale: 1.0)
        let docs = try XCTUnwrap(prep.documents)
        // Eager path only retains blocked documents.
        XCTAssertNotNil(docs.fullBlocked)
        XCTAssertTrue(docs.fullBlocked?.contains("img-src data: cid:") ?? false)
        // Allowed is produced on demand and includes https: in img-src.
        let allowed = docs.document(authored: false, allowRemoteImages: true)
        XCTAssertNotNil(allowed)
        XCTAssertTrue(allowed?.contains("img-src data: cid: https:") ?? false)
        // Authored absent when no quote trail.
        XCTAssertNil(docs.authoredBlocked)
        XCTAssertNil(docs.document(authored: true, allowRemoteImages: false))
    }

    /// `document` is read from MessageCard's SwiftUI body, which re-evaluates
    /// on every height change — assembling per access would stall the main
    /// actor on multi-hundred-KB bodies. Memoized results are shared across
    /// struct copies so the assembly happens once.
    func testMessageHTMLDocumentsAllowedVariantIsMemoizedAcrossCopies() throws {
        let html = "<p>Body <img src=\"https://t.example/p.gif\"></p>"
        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: "Body", bodyHTML: html, fontScale: 1.0)
        let docs = try XCTUnwrap(prep.documents)

        let first = try XCTUnwrap(docs.document(authored: false, allowRemoteImages: true))
        let again = try XCTUnwrap(docs.document(authored: false, allowRemoteImages: true))
        XCTAssertEqual(first, again)

        // A copy reuses the memo rather than reassembling.
        let copy = docs
        XCTAssertEqual(copy.document(authored: false, allowRemoteImages: true), first)
        // Equality ignores the memo — copies stay equal after one side is warmed.
        XCTAssertEqual(copy, docs)
    }

    #if DEBUG
    /// String equality can't distinguish a memo hit from a per-access rebuild
    /// (the jank A2 fixed); the miss counter can.
    func testAllowedVariantAssemblesExactlyOnceAcrossRepeatedAccess() throws {
        let html = "<p>Body <img src=\"https://t.example/p.gif\"></p>"
        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: "Body", bodyHTML: html, fontScale: 1.0)
        let docs = try XCTUnwrap(prep.documents)
        XCTAssertEqual(docs.debugAllowedBuildCount, 0)

        let copy = docs
        _ = docs.document(authored: false, allowRemoteImages: true)
        _ = docs.document(authored: false, allowRemoteImages: true)
        _ = copy.document(authored: false, allowRemoteImages: true)
        XCTAssertEqual(docs.debugAllowedBuildCount, 1)

        // A nil variant (no authored head here) memoizes its miss too.
        _ = docs.document(authored: true, allowRemoteImages: true)
        _ = docs.document(authored: true, allowRemoteImages: true)
        XCTAssertEqual(docs.debugAllowedBuildCount, 2)

        // Blocked variants never touch the memo.
        _ = docs.document(authored: false, allowRemoteImages: false)
        XCTAssertEqual(docs.debugAllowedBuildCount, 2)
    }
    #endif

    // MARK: - Main-actor-safe lookups

    /// `readyDocument` is what the card body calls on the main actor: it must
    /// never assemble, and must return the allowed variant once built.
    func testReadyDocumentNeverBuildsAllowedVariant() throws {
        let html = "<p>Body <img src=\"https://t.example/p.gif\"></p>"
        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: "Body", bodyHTML: html, fontScale: 1.0)
        let docs = try XCTUnwrap(prep.documents)

        XCTAssertEqual(docs.readyDocument(authored: false, allowRemoteImages: false),
                       docs.fullBlocked)
        XCTAssertNil(docs.readyDocument(authored: false, allowRemoteImages: true),
                     "allowed variant is not ready until built off-main")
        #if DEBUG
        XCTAssertEqual(docs.debugAllowedBuildCount, 0)
        #endif

        // Off-main build (what HTMLBodyView does) fills the shared memo.
        let copy = docs
        let built = try XCTUnwrap(copy.document(authored: false, allowRemoteImages: true))
        XCTAssertEqual(docs.readyDocument(authored: false, allowRemoteImages: true), built)
        #if DEBUG
        XCTAssertEqual(docs.debugAllowedBuildCount, 1)
        #endif
    }

    func testAllowedVariantBuildsFromBackgroundTask() async throws {
        let html = "<p>Body <img src=\"https://t.example/p.gif\"></p>"
        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: "Body", bodyHTML: html, fontScale: 1.0)
        let docs = try XCTUnwrap(prep.documents)
        let built = await Task.detached {
            docs.document(authored: false, allowRemoteImages: true)
        }.value
        XCTAssertNotNil(built)
        XCTAssertEqual(docs.readyDocument(authored: false, allowRemoteImages: true), built)
    }

    // MARK: - CID-inlined prep

    func testCIDInlinedPrepScansInlinedHeadAndKeepsPreInlineBytes() throws {
        let image = "data:image/png;base64," + String(repeating: "A", count: 4_000)
        let inlined = """
        <div>New reply <img src="\(image)"></div>
        <div class="gmail_quote">On Mon, Alice wrote:<br>Earlier</div>
        """
        let prep = MessageHTMLPrepBuilder.cidInlinedPrep(
            inlinedHTML: inlined, preInlineBytes: 120, fontScale: 1.0)

        XCTAssertTrue(prep.hasQuotedTrail)
        let head = try XCTUnwrap(prep.htmlHead)
        XCTAssertTrue(head.contains(image), "authored head keeps the inlined image")
        XCTAssertFalse(head.contains("Earlier"))
        XCTAssertNil(prep.textHead)
        XCTAssertEqual(prep.htmlBytes, 120,
                       "oversize gate uses the pre-inline size, not data: growth")
        XCTAssertLessThanOrEqual(prep.htmlHeadBytes, prep.htmlBytes)

        let docs = try XCTUnwrap(prep.documents)
        XCTAssertTrue(try XCTUnwrap(docs.authoredBlocked).contains(image))
        XCTAssertTrue(try XCTUnwrap(docs.fullBlocked).contains("Earlier"))
        // The same scan the card used to run inline.
        XCTAssertEqual(head, QuotedReply.authoredHTMLHead(inlined))
    }

    /// data: payload can push the inlined string past the auto-render budget
    /// while the pre-inline body is small; documents must still be built
    /// (the card auto-renders it) — including the allowed variant.
    func testCIDInlinedPrepAssemblesPastBudgetWhenPreInlineIsSmall() throws {
        let big = String(repeating: "A", count: HTMLBodyRenderPolicy.maximumAutomaticBytes + 10)
        let inlined = "<p>Hi <img src=\"data:image/png;base64,\(big)\"></p>"
        let prep = MessageHTMLPrepBuilder.cidInlinedPrep(
            inlinedHTML: inlined, preInlineBytes: 200, fontScale: 1.0)
        let docs = try XCTUnwrap(prep.documents)
        XCTAssertNotNil(docs.fullBlocked)
        XCTAssertNotNil(docs.document(authored: false, allowRemoteImages: true))
    }

    func testCIDInlinedPrepSkipsDocumentsWhenPreInlineIsOversized() throws {
        let prep = MessageHTMLPrepBuilder.cidInlinedPrep(
            inlinedHTML: "<p>Hi</p>",
            preInlineBytes: HTMLBodyRenderPolicy.maximumAutomaticBytes + 1,
            fontScale: 1.0)
        XCTAssertNil(prep.documents?.fullBlocked,
                     "explicit-approval bodies build their document on demand")
        XCTAssertFalse(prep.hasQuotedTrail)
    }

    /// Reassembling for a new font scale must not serve the old scale's
    /// memoized allowed document.
    func testReassembleDropsMemoizedAllowedVariant() throws {
        let html = "<p>Body <img src=\"https://t.example/p.gif\"></p>"
        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: "Body", bodyHTML: html, fontScale: 1.0)
        let warmed = try XCTUnwrap(prep.documents)
        _ = warmed.document(authored: false, allowRemoteImages: true)

        let rebuilt = MessageHTMLPrepBuilder.reassembleDocuments(
            prep, fullHTML: html, fontScale: 1.6)
        let rebuiltDocs = try XCTUnwrap(rebuilt.documents)
        let allowed = try XCTUnwrap(
            rebuiltDocs.document(authored: false, allowRemoteImages: true))
        XCTAssertEqual(rebuiltDocs.fontScale, 1.6)
        XCTAssertNotEqual(
            allowed, warmed.document(authored: false, allowRemoteImages: true))
    }

    func testBuildBodyPrepMatchesMessageHTMLPrepBuilder() {
        let message = fixtureMessage(
            id: "m1", labels: "INBOX",
            bodyText: "Hi",
            bodyHTML: "<div>Hi</div>")
        let empty = fixtureMessage(id: "m2", labels: "INBOX")
        let prep = ThreadDetailRepository.buildBodyPrep(
            messages: [message, empty], fontScale: 1.0)
        XCTAssertEqual(Set(prep.keys), ["m1"])
        XCTAssertNotNil(prep["m1"]?.documents?.fullBlocked)
        XCTAssertNil(prep["m2"])
    }

    func testRevisionMismatchReloadsPrefetchedThread() async throws {
        let pool = try makeMailPool()
        try await pool.write { db in
            _ = try SyncEngine.upsertPending(
                db, items: [.init(message: self.fixtureMessage(
                    id: "m1", labels: "INBOX"), attachments: [])])
        }
        let repository = ThreadDetailRepository(db: pool)
        var revisions = ThreadContentRevisions()

        let prefetched = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            revision: revisions.revision(of: "thread"))
        XCTAssertFalse(prefetched.cacheHit)
        XCTAssertEqual(prefetched.payload.messages.map(\.id), ["m1"])

        try await pool.write { db in
            _ = try SyncEngine.upsertPending(
                db, items: [.init(message: self.fixtureMessage(
                    id: "m2", labels: "INBOX"), attachments: [])])
        }
        let sameRevision = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            revision: revisions.revision(of: "thread"))
        XCTAssertTrue(sameRevision.cacheHit)
        XCTAssertEqual(sameRevision.payload.messages.map(\.id), ["m1"])

        revisions.apply(.threads(["thread"]))
        let refreshed = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            revision: revisions.revision(of: "thread"))
        XCTAssertFalse(refreshed.cacheHit)
        XCTAssertEqual(
            Set(refreshed.payload.messages.map(\.id)),
            ["m1", "m2"])
    }

    /// The regression this scoping exists for: triage mutates *other* rows all
    /// the time, and each one used to evict the warmed neighbor the user was
    /// about to land on.
    func testUnrelatedThreadChangeKeepsAWarmedPayloadCached() async throws {
        let pool = try makeMailPool()
        try await pool.write { db in
            _ = try SyncEngine.upsertPending(
                db, items: [.init(message: self.fixtureMessage(
                    id: "m1", labels: "INBOX"), attachments: [])])
        }
        let repository = ThreadDetailRepository(db: pool)
        var revisions = ThreadContentRevisions()

        let warmed = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            revision: revisions.revision(of: "thread"))
        XCTAssertFalse(warmed.cacheHit)

        // A neighbouring conversation was trashed, archived, starred, read…
        revisions.apply(.threads(["some-other-thread"]))

        let landed = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            revision: revisions.revision(of: "thread"))
        XCTAssertTrue(landed.cacheHit)
    }

    func testEverythingChangeEvictsEveryWarmedPayload() async throws {
        let pool = try makeMailPool()
        try await pool.write { db in
            _ = try SyncEngine.upsertPending(
                db, items: [.init(message: self.fixtureMessage(
                    id: "m1", labels: "INBOX"), attachments: [])])
        }
        let repository = ThreadDetailRepository(db: pool)
        var revisions = ThreadContentRevisions()
        _ = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            revision: revisions.revision(of: "thread"))

        revisions.apply(.everything)

        let landed = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            revision: revisions.revision(of: "thread"))
        XCTAssertFalse(landed.cacheHit)
    }

    /// Suppression is applied to the returned copy, never baked into the cache,
    /// so toggling it during an Undo-send window must not cost a reload.
    func testDraftSuppressionChangeStillHitsTheCache() async throws {
        let pool = try makeMailPool()
        try await pool.write { db in
            _ = try SyncEngine.upsertPending(
                db, items: [
                    .init(message: self.fixtureMessage(id: "m1", labels: "INBOX"),
                          attachments: []),
                    .init(message: self.fixtureMessage(id: "d1", labels: "DRAFT"),
                          attachments: []),
                ])
        }
        let repository = ThreadDetailRepository(db: pool)
        let revisions = ThreadContentRevisions()
        let revision = revisions.revision(of: "thread")
        _ = await repository.payload(
            threadId: "thread", suppressingDrafts: [], revision: revision)

        let suppressed = await repository.payload(
            threadId: "thread", suppressingDrafts: ["d1"], revision: revision)

        XCTAssertTrue(suppressed.cacheHit)
        XCTAssertEqual(suppressed.payload.messages.map(\.id), ["m1"])
    }

    private func makeMailPool() throws -> DatabasePool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-detail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("mail.sqlite").path)
        try AppDatabase.migrator.migrate(pool)
        try pool.write { db in
            try Account(
                id: "me@example.com", displayName: "Me", historyId: nil,
                lastSyncAt: nil, senderName: "Me").insert(db)
        }
        return pool
    }

    private func fixtureMessage(id: String, labels: String,
                                bodyText: String = "",
                                bodyHTML: String? = nil) -> Message {
        Message(
            id: id, accountId: "me@example.com", gmailId: id, threadId: "thread",
            fromHeader: "A <a@example.com>", toHeader: "me@example.com",
            ccHeader: "", subject: "Subject", date: Date(), snippet: "",
            bodyText: bodyText, bodyHTML: bodyHTML, messageIdHeader: "<\(id)>",
            referencesHeader: "", labelIds: labels, isUnread: false,
            hasAttachment: false)
    }

    /// The VIP remote-image gate reads `message.senderAuth` from the pane's
    /// Message. The initial frame comes from fetchPayload's custom SELECT,
    /// which must project the column explicitly — otherwise the verdict is
    /// nil on every auto-expanded message and the gate never engages.
    func testFetchPayloadProjectsSenderAuth() async throws {
        let pool = try makeMailPool()
        try await pool.write { db in
            var message = self.fixtureMessage(id: "m1", labels: "INBOX")
            message.senderAuth = false
            _ = try SyncEngine.upsertPending(
                db, items: [.init(message: message, attachments: [])])
        }
        let payload = try await pool.read { db in
            try ThreadDetailRepository.fetchPayload(threadId: "thread", db: db)
        }
        XCTAssertEqual(payload.messages.map(\.senderAuth), [false])
    }

    /// Reply reads `message.replyToHeader` from the pane's Message. The
    /// custom SELECT must project it, or every reply from the reading pane
    /// goes to From even when the row has a recorded Reply-To.
    func testFetchPayloadProjectsReplyToHeader() async throws {
        let pool = try makeMailPool()
        try await pool.write { db in
            var message = self.fixtureMessage(id: "m1", labels: "INBOX")
            message.replyToHeader = "desk@help.example"
            _ = try SyncEngine.upsertPending(
                db, items: [.init(message: message, attachments: [])])
        }
        let payload = try await pool.read { db in
            try ThreadDetailRepository.fetchPayload(threadId: "thread", db: db)
        }
        XCTAssertEqual(payload.messages.map(\.replyToHeader), ["desk@help.example"])
    }

    // MARK: - Unsubscribe back-fill

    /// The reading pane back-fills List-Unsubscribe for rows where it reads
    /// nil. When the open query did not project the column, every row read
    /// nil, so every open paid three extra row reads and three whole-thread
    /// re-renders. A parsed row stores "" for an absent header: it must reach
    /// the pane as "", which leaves the back-fill nothing to do.
    func testFetchPayloadProjectsListUnsubscribeSoOpenSkipsTheBackfill() async throws {
        let pool = try makeMailPool()
        try await pool.write { db in
            var withHeader = self.fixtureMessage(id: "m1", labels: "INBOX")
            withHeader.listUnsubscribe = "<https://list.example/u>"
            withHeader.listUnsubscribePost = "List-Unsubscribe=One-Click"
            var without = self.fixtureMessage(id: "m2", labels: "INBOX")
            without.listUnsubscribe = ""
            without.listUnsubscribePost = ""
            _ = try SyncEngine.upsertPending(
                db, items: [.init(message: withHeader, attachments: []),
                            .init(message: without, attachments: [])])
        }
        let payload = try await pool.read { db in
            try ThreadDetailRepository.fetchPayload(threadId: "thread", db: db)
        }
        XCTAssertEqual(payload.messages.map(\.listUnsubscribe),
                       ["<https://list.example/u>", ""])
        XCTAssertEqual(payload.messages.map(\.listUnsubscribePost),
                       ["List-Unsubscribe=One-Click", ""])
        // What `backfillUnsubscribeHeaders` selects.
        XCTAssertTrue(payload.messages.filter { $0.listUnsubscribe == nil }.isEmpty)
    }

    // MARK: - Resolved cid: images

    private func cidBody(_ marker: String = "img") -> CIDInlinedBody {
        let html = "<p>Logo <img src=\"data:image/png;base64,\(marker)\"></p>"
        return CIDInlinedBody(
            html: html,
            prep: MessageHTMLPrepBuilder.cidInlinedPrep(
                inlinedHTML: html, preInlineBytes: 40, fontScale: 1.0))
    }

    private func seededRepository() async throws
        -> (ThreadDetailRepository, ThreadContentRevisions) {
        let pool = try makeMailPool()
        try await pool.write { db in
            _ = try SyncEngine.upsertPending(
                db, items: [.init(message: self.fixtureMessage(
                    id: "m1", labels: "INBOX", bodyText: "Logo",
                    bodyHTML: "<p>Logo <img src=\"cid:logo\"></p>"),
                                  attachments: [])])
        }
        let repository = ThreadDetailRepository(db: pool)
        let revisions = ThreadContentRevisions()
        _ = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            revision: revisions.revision(of: "thread"))
        return (repository, revisions)
    }

    /// The re-open path: a resolved body rides on the cached payload, and
    /// seeding the pane from it marks the message attempted — which is the
    /// guard that keeps `resolveCIDImagesIfNeeded` off the network.
    func testReopenServesResolvedCIDBodyAndMakesNoAttachmentRequest() async throws {
        let (repository, revisions) = try await seededRepository()
        let revision = revisions.revision(of: "thread")
        let stored = await repository.rememberCIDInline(
            cidBody(), messageId: "m1", threadId: "thread",
            revision: revision, fontScale: 1.0)
        XCTAssertTrue(stored)

        let reopened = await repository.payload(
            threadId: "thread", suppressingDrafts: [], revision: revision)
        XCTAssertTrue(reopened.cacheHit, "no database read on re-open")
        XCTAssertEqual(reopened.payload.cidInlineByMessageId["m1"], cidBody())

        let seed = CIDInlineSeed.seed(from: reopened.payload, fontScale: 1.0)
        XCTAssertEqual(seed.resolvedIds, ["m1"],
                       "attempted before the card asks: zero getAttachment calls")
        XCTAssertEqual(seed.htmlById["m1"], cidBody().html)
        XCTAssertNotNil(seed.prepById["m1"]?.documents?.fullBlocked,
                        "documents prebuilt: no re-assembly on the main actor")
        XCTAssertFalse(seed.needsResolve("m1", attempted: []),
                       "the pane's resolver guard sees it as done")
    }

    func testSeedIgnoresBodiesOfMessagesNotInThePayload() {
        var payload = ThreadDetailPayload(
            messages: [fixtureMessage(id: "m1", labels: "INBOX")],
            attachmentsByMessageId: [:], bodyPrepByMessageId: [:])
        payload.cidInlineByMessageId["gone"] = cidBody()
        XCTAssertTrue(CIDInlineSeed.seed(from: payload, fontScale: 1.0).resolvedIds.isEmpty)
    }

    func testResolvedCIDBodyIsNotStoredAgainstAStaleRevisionOrScale() async throws {
        let (repository, revisions) = try await seededRepository()
        var moved = revisions
        moved.apply(.threads(["thread"]))
        let staleRevision = await repository.rememberCIDInline(
            cidBody(), messageId: "m1", threadId: "thread",
            revision: moved.revision(of: "thread"), fontScale: 1.0)
        XCTAssertFalse(staleRevision)
        let otherScale = await repository.rememberCIDInline(
            cidBody(), messageId: "m1", threadId: "thread",
            revision: revisions.revision(of: "thread"), fontScale: 1.25)
        XCTAssertFalse(otherScale)
        let unknownThread = await repository.rememberCIDInline(
            cidBody(), messageId: "m1", threadId: "never-opened",
            revision: revisions.revision(of: "never-opened"), fontScale: 1.0)
        XCTAssertFalse(unknownThread, "never creates an entry of its own")
    }

    func testFontScaleChangeDropsResolvedCIDBodies() async throws {
        let (repository, revisions) = try await seededRepository()
        let revision = revisions.revision(of: "thread")
        await repository.rememberCIDInline(
            cidBody(), messageId: "m1", threadId: "thread",
            revision: revision, fontScale: 1.0)
        let rescaled = await repository.payload(
            threadId: "thread", suppressingDrafts: [], revision: revision,
            fontScale: 1.25)
        XCTAssertTrue(rescaled.payload.cidInlineByMessageId.isEmpty)
    }

    func testDraftSuppressionFiltersResolvedCIDBodies() {
        var payload = ThreadDetailPayload(
            messages: [fixtureMessage(id: "m1", labels: "INBOX"),
                       fixtureMessage(id: "d1", labels: "DRAFT")],
            attachmentsByMessageId: [:], bodyPrepByMessageId: [:])
        payload.cidInlineByMessageId = ["m1": cidBody("a"), "d1": cidBody("b")]
        let visible = payload.suppressingDrafts(["d1"])
        XCTAssertEqual(Set(visible.cidInlineByMessageId.keys), ["m1"])
    }

    // MARK: - Deleted means gone (memory)

    /// A content change (a delete among them) must take the stale payload,
    /// with its decoded bodies and resolved images, out of memory — not leave
    /// it until ten more conversations evict it.
    func testContentChangeDiscardsTheStalePayloadFromMemory() async throws {
        let (repository, revisions) = try await seededRepository()
        await repository.rememberCIDInline(
            cidBody(), messageId: "m1", threadId: "thread",
            revision: revisions.revision(of: "thread"), fontScale: 1.0)
        var moved = revisions
        moved.apply(.threads(["thread"]))
        await repository.discardStale(
            .threads(["thread": moved.revision(of: "thread")]))
        let cached = await repository.cachedThreadIds()
        XCTAssertFalse(cached.contains("thread"))
    }

    /// The discard runs in a task, so a reload for the new revision may land
    /// first. That fresh entry must survive.
    func testDiscardKeepsAnEntryAlreadyRebuiltForTheNewRevision() async throws {
        let (repository, revisions) = try await seededRepository()
        var moved = revisions
        moved.apply(.threads(["thread"]))
        let current = moved.revision(of: "thread")
        _ = await repository.payload(
            threadId: "thread", suppressingDrafts: [], revision: current)
        await repository.discardStale(.threads(["thread": current]))
        let again = await repository.payload(
            threadId: "thread", suppressingDrafts: [], revision: current)
        XCTAssertTrue(again.cacheHit)
    }

    func testEpochChangeDiscardsEveryOlderPayload() async throws {
        let (repository, revisions) = try await seededRepository()
        var moved = revisions
        moved.apply(.everything)
        await repository.discardStale(.before(epoch: moved.epoch))
        let cached = await repository.cachedThreadIds()
        XCTAssertTrue(cached.isEmpty)
    }

    func testMirrorDropsChangedThreadsAndCarriesResolvedCIDBodies() {
        var mirror = ThreadDetailMirror(capacity: 4)
        let revisions = ThreadContentRevisions()
        let payload = ThreadDetailPayload(
            messages: [fixtureMessage(id: "m1", labels: "INBOX")],
            attachmentsByMessageId: [:], bodyPrepByMessageId: [:])
        let revision = revisions.revision(of: "thread")
        mirror.store(payload, for: "thread", revision: revision, current: revision,
                     suppressing: [])
        mirror.store(payload, for: "other", revision: revision, current: revision,
                     suppressing: [])

        mirror.rememberCIDInline(cidBody(), messageId: "m1", threadId: "thread",
                                 revision: revision, fontScale: 1.0)
        XCTAssertEqual(
            mirror.payload(for: "thread", revision: revision, suppressing: [])?
                .cidInlineByMessageId["m1"], cidBody(),
            "the synchronous warm open sees the resolved images too")

        mirror.invalidate(.threads(["thread"]))
        XCTAssertNil(mirror.payload(for: "thread", revision: revision, suppressing: []))
        XCTAssertNotNil(mirror.payload(for: "other", revision: revision, suppressing: []))
        mirror.invalidate(.everything)
        XCTAssertNil(mirror.payload(for: "other", revision: revision, suppressing: []))
    }

    // MARK: - Review round: late stores, cache policy, wiring

    /// A load stamped before a change (a delete) that lands after it must
    /// not put the stale payload back in the mirror.
    func testMirrorDropsALateStoreStampedBeforeAChange() {
        var mirror = ThreadDetailMirror(capacity: 4)
        var revisions = ThreadContentRevisions()
        let stamped = revisions.revision(of: "thread")
        let payload = ThreadDetailPayload(
            messages: [fixtureMessage(id: "m1", labels: "INBOX")],
            attachmentsByMessageId: [:], bodyPrepByMessageId: [:])
        revisions.apply(.threads(["thread"]))   // the delete lands
        mirror.store(payload, for: "thread", revision: stamped,
                     current: revisions.revision(of: "thread"), suppressing: [])
        XCTAssertNil(mirror.payload(for: "thread", revision: stamped, suppressing: []))
    }

    /// Same for the repository: its read and the discard are serialized on
    /// the actor, but the discard can run first.
    func testRepositoryDoesNotCacheAReadSupersededByAKnownChange() async throws {
        let (repository, revisions) = try await seededRepository()
        let stamped = revisions.revision(of: "thread")
        var moved = revisions
        moved.apply(.threads(["thread"]))
        await repository.discardStale(.threads(["thread": moved.revision(of: "thread")]))
        let late = await repository.payload(
            threadId: "thread", suppressingDrafts: [], revision: stamped)
        XCTAssertFalse(late.cacheHit)
        let cached = await repository.cachedThreadIds()
        XCTAssertFalse(cached.contains("thread"), "late stale read stays out of memory")

        var epochMoved = revisions
        epochMoved.apply(.everything)
        await repository.discardStale(.before(epoch: epochMoved.epoch))
        _ = await repository.payload(
            threadId: "thread", suppressingDrafts: [],
            revision: moved.revision(of: "thread"))
        let afterEpoch = await repository.cachedThreadIds()
        XCTAssertTrue(afterEpoch.isEmpty)
    }

    /// A part that failed to download leaves its `cid:` reference: that body
    /// must be resolved again next time, not frozen with a broken image.
    func testPartiallyResolvedBodyIsNotRemembered() async throws {
        let (repository, revisions) = try await seededRepository()
        let html = "<p><img src=\"data:image/png;base64,AA\"><img src=\"cid:missing\"></p>"
        let partial = CIDInlinedBody(
            html: html,
            prep: MessageHTMLPrepBuilder.cidInlinedPrep(
                inlinedHTML: html, preInlineBytes: 60, fontScale: 1.0))
        XCTAssertFalse(CIDInlineCachePolicy.shouldRemember(partial, fontScale: 1.0))
        let stored = await repository.rememberCIDInline(
            partial, messageId: "m1", threadId: "thread",
            revision: revisions.revision(of: "thread"), fontScale: 1.0)
        XCTAssertFalse(stored)
    }

    func testOversizedResolvedBodyIsNotRemembered() {
        let html = "<p><img src=\"data:image/png;base64,"
            + String(repeating: "A", count: CIDInlineCachePolicy.maximumBytes) + "\"></p>"
        let big = CIDInlinedBody(html: html, prep: .empty)
        XCTAssertFalse(CIDInlineCachePolicy.shouldRemember(big, fontScale: 1.0))
        var mirror = ThreadDetailMirror(capacity: 4)
        let revision = ThreadContentRevisions().revision(of: "thread")
        mirror.store(ThreadDetailPayload(
            messages: [fixtureMessage(id: "m1", labels: "INBOX")],
            attachmentsByMessageId: [:], bodyPrepByMessageId: [:]),
            for: "thread", revision: revision, current: revision, suppressing: [])
        mirror.rememberCIDInline(big, messageId: "m1", threadId: "thread",
                                 revision: revision, fontScale: 1.0)
        XCTAssertNil(mirror.payload(for: "thread", revision: revision, suppressing: [])?
            .cidInlineByMessageId["m1"])
        XCTAssertTrue(CIDInlineCachePolicy.shouldRemember(cidBody(), fontScale: 1.0))
    }

    /// The mirror has no scale of its own: the policy and the seed both
    /// refuse a body built at another scale.
    func testResolvedBodyAtAnotherFontScaleIsNeitherRememberedNorSeeded() {
        XCTAssertFalse(CIDInlineCachePolicy.shouldRemember(cidBody(), fontScale: 1.25))
        var payload = ThreadDetailPayload(
            messages: [fixtureMessage(id: "m1", labels: "INBOX")],
            attachmentsByMessageId: [:], bodyPrepByMessageId: [:])
        payload.cidInlineByMessageId["m1"] = cidBody()
        let seed = CIDInlineSeed.seed(from: payload, fontScale: 1.25)
        XCTAssertTrue(seed.resolvedIds.isEmpty)
        XCTAssertTrue(seed.needsResolve("m1", attempted: []))
    }

    /// The fan-out `MailStore.applyThreadContentChange` runs: revisions move,
    /// the mirror drops the thread, and the repository / pre-render slots get
    /// exactly the threads (or everything) to discard.
    func testInvalidationDropsMirrorAndNamesWhatTheRepositoryAndPrerenderDrop() {
        var revisions = ThreadContentRevisions()
        var mirror = ThreadDetailMirror(capacity: 4)
        let before = revisions.revision(of: "thread")
        let payload = ThreadDetailPayload(
            messages: [fixtureMessage(id: "m1", labels: "INBOX")],
            attachmentsByMessageId: [:], bodyPrepByMessageId: [:])
        mirror.store(payload, for: "thread", revision: before, current: before,
                     suppressing: [])
        mirror.store(payload, for: "other", revision: before, current: before,
                     suppressing: [])

        XCTAssertNil(ThreadDetailInvalidation.apply(
            .none, revisions: &revisions, mirror: &mirror))

        let outcome = ThreadDetailInvalidation.apply(
            .threads(["thread"]), revisions: &revisions, mirror: &mirror)
        XCTAssertEqual(outcome?.staleness,
                       .threads(["thread": revisions.revision(of: "thread")]))
        XCTAssertEqual(outcome?.affectedThreadIds, ["thread"])
        XCTAssertNil(mirror.payload(for: "thread", revision: before, suppressing: []))
        XCTAssertNotNil(mirror.payload(for: "other", revision: before, suppressing: []))

        let all = ThreadDetailInvalidation.apply(
            .everything, revisions: &revisions, mirror: &mirror)
        XCTAssertEqual(all?.staleness, .before(epoch: revisions.epoch))
        XCTAssertNil(all?.affectedThreadIds)
        XCTAssertNil(mirror.payload(for: "other", revision: before, suppressing: []))
    }

    func testPrerenderOwnershipHandsBackOnlyTheChangedThreadsViews() {
        var ownership = PrerenderOwnership()
        ownership.record(poolKey: "m1:full|r=0|f=1.000", threadId: "t1")
        ownership.record(poolKey: "m2:authored|r=0|f=1.000", threadId: "t2")
        XCTAssertEqual(ownership.take(threadIds: ["t1"]), ["m1:full|r=0|f=1.000"])
        XCTAssertEqual(ownership.take(threadIds: ["t1"]), [], "taken once")
        ownership.record(poolKey: "m3:full|r=0|f=1.000", threadId: "t3")
        XCTAssertEqual(Set(ownership.take(threadIds: nil)),
                       ["m2:authored|r=0|f=1.000", "m3:full|r=0|f=1.000"])
        for n in 0..<(PrerenderOwnership.capacity + 5) {
            ownership.record(poolKey: "k\(n)", threadId: "t")
        }
        XCTAssertEqual(ownership.threadByPoolKey.count, PrerenderOwnership.capacity)
    }

    private func fixtureAttachment(messageId: String) -> AttachmentRow {
        AttachmentRow(
            id: nil, messageId: messageId, gmailAttachmentId: "att",
            filename: "file.txt", mimeType: "text/plain", size: 1)
    }
}
