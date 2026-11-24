import Foundation

/// A message body with every cacheable remote image inlined from the
/// encrypted cache as a `data:` URL, plus the prep built from it off the main
/// actor. Only ever built from the cache (no network), and only when every
/// candidate the app may cache is there (or was refused): a message whose
/// images are not all cached opens exactly as without the cache.
///
/// Shown with the blocked CSP when `needsNetwork` is false (nothing left to
/// fetch, so a blocked pre-render of the same body can be claimed), else with
/// the allowed CSP so what the app could not cache loads live as before.
struct RemoteInlinedBody: Equatable, Sendable {
    var html: String
    var prep: MessageHTMLPrep
    /// Something in `html` can still load a remote image.
    var needsNetwork: Bool
    /// Candidate occurrences rewritten to `data:`.
    var inlinedCount: Int
    /// Built on the `cid:`-inlined body rather than the stored one.
    var baseIsCIDInlined: Bool

    /// Appended to the card's content id (`HTMLBodyLoadKey`).
    var contentSuffix: String { ":rimg" }

    /// The CSP variant the card loads this body with.
    var loadAllowsRemoteImages: Bool { needsNetwork }
}

/// Builds `RemoteInlinedBody`s from the cache only (`cachedBody`: the
/// prefetch and the pane), and fills the cache for the next open
/// (`fetchForNextOpen`: only for a message that is open with its remote
/// images allowed, while WebKit shows them live as without the cache).
/// Never logs.
enum RemoteImageResolver {
    /// What the cache says about one body.
    struct Lookup: Sendable {
        /// Candidate URLs the app may fetch (at most
        /// `RemoteImageFetchPolicy.maxImagesPerMessage`).
        var eligible: [String]
        var dataURLs: [String: String]
        var cachedBytes: Int
        /// Eligible, not cached, not failed earlier this run.
        var misses: [String]
    }

    static func lookup(messageId: String, accountId: String, baseHTML: String,
                       store: RemoteImageStore?) async -> Lookup? {
        let urls = RemoteImageHTML.candidates(in: baseHTML)
        guard !urls.isEmpty else { return nil }
        let eligible = Array(urls.prefix(RemoteImageFetchPolicy.maxImagesPerMessage))
        let keys = eligible.map(RemoteImageHTML.urlKey)
        var cached: [String: RemoteImageCache.Image] = [:]
        var failed: Set<String> = []
        if let store {
            cached = await store.cachedImages(messageId: messageId, accountId: accountId,
                                              urlKeys: keys)
            failed = await store.failedKeys(messageId: messageId, among: keys)
        }
        var dataURLs: [String: String] = [:]
        var cachedBytes = 0
        var misses: [String] = []
        for (url, key) in zip(eligible, keys) {
            if let image = cached[key] {
                dataURLs[url] = CIDImageInliner.dataURI(mimeType: image.mimeType, data: image.data)
                cachedBytes += image.data.count
            } else if !failed.contains(key) {
                misses.append(url)
            }
        }
        return Lookup(eligible: eligible, dataURLs: dataURLs, cachedBytes: cachedBytes,
                      misses: misses)
    }

    /// The body from the cache, with no network: nil unless it has a
    /// candidate, every eligible candidate is cached or was refused, and at
    /// least one is cached. Completeness is checked first on the keys alone
    /// (an index-only read), so an incomplete cache reads no image bytes.
    static func cachedBody(messageId: String, accountId: String, baseHTML: String,
                           preInlineBytes: Int, baseIsCIDInlined: Bool, fontScale: Double,
                           store: RemoteImageStore?) async -> RemoteInlinedBody? {
        guard let store else { return nil }
        let urls = RemoteImageHTML.candidates(in: baseHTML)
        guard !urls.isEmpty else { return nil }
        let keys = urls.prefix(RemoteImageFetchPolicy.maxImagesPerMessage)
            .map(RemoteImageHTML.urlKey)
        let stored = await store.storedKeys(messageId: messageId, accountId: accountId)
        let failed = await store.failedKeys(messageId: messageId, among: keys)
        guard !stored.isEmpty, keys.allSatisfy({ stored.contains($0) || failed.contains($0) }),
              !Task.isCancelled else { return nil }
        guard let found = await lookup(messageId: messageId, accountId: accountId,
                                       baseHTML: baseHTML, store: store),
              found.misses.isEmpty, !found.dataURLs.isEmpty,
              !Task.isCancelled else { return nil }
        return build(baseHTML: baseHTML, dataURLs: found.dataURLs,
                     preInlineBytes: preInlineBytes, baseIsCIDInlined: baseIsCIDInlined,
                     fontScale: fontScale)
    }

    /// The open's background work: fetch what the cache lacks (the app's
    /// own client, within the caps, never a URL already in flight for this
    /// message) and queue it for storage. The open itself is not changed:
    /// WebKit shows the images live, as without the cache. Returns the body
    /// the next open can show, when everything is now cached, so the caller
    /// can keep it with the payload; a cache-only result marks the message
    /// as used.
    static func fetchForNextOpen(messageId: String, accountId: String, baseHTML: String,
                                 preInlineBytes: Int, baseIsCIDInlined: Bool, fontScale: Double,
                                 store: RemoteImageStore?,
                                 transport: RemoteImageTransport) async -> RemoteInlinedBody? {
        guard let found = await lookup(messageId: messageId, accountId: accountId,
                                       baseHTML: baseHTML, store: store) else { return nil }
        var dataURLs = found.dataURLs
        if found.misses.isEmpty {
            guard !dataURLs.isEmpty else { return nil }
            await store?.noteUsed([messageId])
            return build(baseHTML: baseHTML, dataURLs: dataURLs, preInlineBytes: preInlineBytes,
                         baseIsCIDInlined: baseIsCIDInlined, fontScale: fontScale)
        }
        // Within the message's byte cap; never a URL another resolve of the
        // same message is already fetching.
        let room = RemoteImageFetchPolicy.maxMessageBytes - found.cachedBytes
        var mine: [String] = []
        if room > 0 {
            if let store {
                mine = await store.claim(messageId: messageId, urls: found.misses)
            } else {
                mine = found.misses
            }
        }
        var batch = RemoteImageFetcher.Batch()
        if !mine.isEmpty {
            batch = await RemoteImageFetcher.fetchAll(mine, byteBudget: room, transport: transport)
        }
        // In document order, within the message's cap.
        var used = found.cachedBytes
        var newImages: [RemoteImageCache.Image] = []
        var refusedKeys: [String] = []
        var settled = Set(mine.filter { batch.refused.contains($0) })
        for url in mine {
            let key = RemoteImageHTML.urlKey(url)
            if batch.refused.contains(url) { refusedKeys.append(key) }
            guard let image = batch.images[url] else { continue }
            guard used + image.data.count <= RemoteImageFetchPolicy.maxMessageBytes else {
                // Over the message's cap: a rule, not the network.
                refusedKeys.append(key)
                settled.insert(url)
                continue
            }
            used += image.data.count
            settled.insert(url)
            dataURLs[url] = CIDImageInliner.dataURI(mimeType: image.mimeType, data: image.data)
            newImages.append(RemoteImageCache.Image(urlKey: key, mimeType: image.mimeType,
                                                    data: image.data))
        }
        if let store {
            if !refusedKeys.isEmpty {
                await store.noteFailed(messageId: messageId, urlKeys: refusedKeys)
            }
            if !newImages.isEmpty {
                await store.remember(RemoteImageCache.Pending(
                    messageId: messageId, accountId: accountId, images: newImages))
            }
            await store.release(messageId: messageId, urls: mine)
        }
        // The next open's body, only when nothing is left to fetch.
        guard !Task.isCancelled, !dataURLs.isEmpty,
              Set(found.misses).isSubset(of: settled) else { return nil }
        return build(baseHTML: baseHTML, dataURLs: dataURLs, preInlineBytes: preInlineBytes,
                     baseIsCIDInlined: baseIsCIDInlined, fontScale: fontScale)
    }

    /// Rewrite and prep: whole-body string work, off the main actor.
    static func build(baseHTML: String, dataURLs: [String: String], preInlineBytes: Int,
                      baseIsCIDInlined: Bool, fontScale: Double) -> RemoteInlinedBody {
        let rewritten = RemoteImageHTML.rewrite(baseHTML, dataURLs: dataURLs)
        let prep = MessageHTMLPrepBuilder.cidInlinedPrep(
            inlinedHTML: rewritten.html, preInlineBytes: preInlineBytes, fontScale: fontScale,
            countRemoteCandidates: false)
        return RemoteInlinedBody(
            html: rewritten.html, prep: prep,
            needsNetwork: rewritten.needsNetwork, inlinedCount: rewritten.rewrittenCount,
            baseIsCIDInlined: baseIsCIDInlined)
    }
}

/// Which body the reading pane and the neighbour pre-render paint for a
/// message, given its remote-image decision. Pure, so the "never ahead of
/// time" and "same document for pre-render and open" rules are testable.
enum RemoteImageRendering {
    enum Choice: Equatable {
        /// The stored (or `cid:`-inlined) body with the CSP the decision
        /// gives: exactly as without the cache.
        case base(allowRemoteImages: Bool)
        /// The body with every cacheable image from the cache.
        case remote(RemoteInlinedBody)
        /// The cache check for this open is running (a few milliseconds):
        /// the body is not painted yet, so it never loads live first and
        /// then again from the cache.
        case awaitingCacheCheck
    }

    /// The card's choice. `remoteBody` (complete, from the cache, present
    /// when the payload was warmed or a previous open filled it) is used
    /// only when remote images are allowed for this message and it was built
    /// on the same base.
    /// `awaitingCacheCheck`: the pane has not yet checked the cache for
    /// this base. While it checks, a body built on the other base (before a
    /// `cid:` resolve landed) is kept on screen; otherwise nothing paints.
    static func choice(allowRemoteImages: Bool, remoteBody: RemoteInlinedBody?,
                       cidInlined: Bool, awaitingCacheCheck: Bool = false) -> Choice {
        guard allowRemoteImages else { return .base(allowRemoteImages: false) }
        if let remoteBody, remoteBody.baseIsCIDInlined == cidInlined {
            return .remote(remoteBody)
        }
        if awaitingCacheCheck {
            if let remoteBody { return .remote(remoteBody) }
            return .awaitingCacheCheck
        }
        return .base(allowRemoteImages: true)
    }

    /// What the reading pane does for one card, each time the card's
    /// decision or base changes.
    enum PaneStep: Equatable {
        /// Images not allowed (never were, or no longer: the card left, the
        /// message went to Spam, the policy became Ask): stop any fetch for
        /// this message; nothing is read or fetched.
        case cancel
        /// A `cid:` resolve is changing the base: start after it.
        case waitForCID
        /// The card shows the body from the cache: only mark it used.
        case markCachedUsed
        /// Not checked yet for this base: read the cache (keys first) before
        /// the body paints; a complete cache is shown with no request.
        case checkCache(baseIsCIDInlined: Bool)
        /// No remote image the app could cache: nothing to do.
        case nothing
        /// The card shows images live; fetch the cacheable ones in the
        /// background for the next open, on this base.
        case fetchForNextOpen(baseIsCIDInlined: Bool)
    }

    /// The gate every pane fetch goes through: `allowRemoteImages` is the
    /// card's `RemoteImagePolicy.autoLoads` decision, opt-ins included.
    static func paneStep(allowRemoteImages: Bool, remoteCandidateCount: Int,
                         cacheChecked: Bool, cidResolveInFlight: Bool, cidInlined: Bool,
                         remoteBody: RemoteInlinedBody?) -> PaneStep {
        guard allowRemoteImages else { return .cancel }
        if let body = remoteBody, body.baseIsCIDInlined == cidInlined { return .markCachedUsed }
        guard remoteCandidateCount > 0 else { return .nothing }
        if !cacheChecked { return .checkCache(baseIsCIDInlined: cidInlined) }
        if cidResolveInFlight { return .waitForCID }
        return .fetchForNextOpen(baseIsCIDInlined: cidInlined)
    }

    /// What the neighbour pre-render paints (always with the blocked CSP),
    /// or nil to skip: the document the open would claim, never one that
    /// needs the network.
    static func prerender(opensWithRemoteImages: Bool, remoteBody: RemoteInlinedBody?,
                          cidInlined: Bool) -> Choice? {
        switch choice(allowRemoteImages: opensWithRemoteImages, remoteBody: remoteBody,
                      cidInlined: cidInlined) {
        case .base(let allow):
            return allow ? nil : .base(allowRemoteImages: false)
        case .remote(let body):
            return body.loadAllowsRemoteImages ? nil : .remote(body)
        case .awaitingCacheCheck:
            return nil
        }
    }
}
