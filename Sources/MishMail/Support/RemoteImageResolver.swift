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
        var dataURLs: [String: String]
        var cachedBytes: Int
        /// Eligible URLs neither cached nor refused.
        var misses: [String]
    }

    /// The candidates the app may cache: at most
    /// `RemoteImageFetchPolicy.maxImagesPerMessage`, in document order.
    static func eligibleURLs(in baseHTML: String) -> [String] {
        Array(RemoteImageHTML.candidates(in: baseHTML).prefix(RemoteImageFetchPolicy.maxImagesPerMessage))
    }

    /// Reads the cached images of `eligible` (refusal markers excluded) and
    /// what is still missing. `settled`: the keys already known to be cached
    /// or refused, when the caller has them.
    static func lookup(messageId: String, accountId: String, eligible: [String],
                       settled known: Set<String>? = nil,
                       store: RemoteImageStore?) async -> Lookup {
        let keys = eligible.map(RemoteImageHTML.urlKey)
        var cached: [String: RemoteImageCache.Image] = [:]
        var settled: Set<String> = []
        if let store {
            if let known {
                settled = known
            } else {
                settled = await store.storedKeys(messageId: messageId, accountId: accountId)
            }
            let present = keys.filter { settled.contains($0) }
            cached = await store.cachedImages(messageId: messageId, accountId: accountId,
                                              urlKeys: present)
        }
        var dataURLs: [String: String] = [:]
        var cachedBytes = 0
        var misses: [String] = []
        for (url, key) in zip(eligible, keys) {
            if let image = cached[key] {
                dataURLs[url] = CIDImageInliner.dataURI(mimeType: image.mimeType, data: image.data)
                cachedBytes += image.data.count
            } else if !settled.contains(key) {
                misses.append(url)
            }
        }
        return Lookup(dataURLs: dataURLs, cachedBytes: cachedBytes, misses: misses)
    }

    /// Whether every eligible candidate of `eligible` is cached or refused,
    /// from the keys alone (an index-only read, no image bytes).
    static func isComplete(messageId: String, accountId: String, eligible: [String],
                           store: RemoteImageStore) async -> (complete: Bool, settled: Set<String>) {
        let settled = await store.storedKeys(messageId: messageId, accountId: accountId)
        let complete = !eligible.isEmpty
            && eligible.allSatisfy { settled.contains(RemoteImageHTML.urlKey($0)) }
        return (complete, settled)
    }

    /// The body from the cache, with no network: nil unless it has a
    /// candidate, every eligible candidate is cached or refused, and at
    /// least one is cached. Completeness is decided on the keys first, so an
    /// incomplete cache reads no image bytes.
    static func cachedBody(messageId: String, accountId: String, baseHTML: String,
                           preInlineBytes: Int, baseIsCIDInlined: Bool, fontScale: Double,
                           store: RemoteImageStore?) async -> RemoteInlinedBody? {
        guard let store else { return nil }
        let eligible = eligibleURLs(in: baseHTML)
        let check = await isComplete(messageId: messageId, accountId: accountId,
                                     eligible: eligible, store: store)
        guard check.complete, !Task.isCancelled else { return nil }
        let found = await lookup(messageId: messageId, accountId: accountId, eligible: eligible,
                                 settled: check.settled, store: store)
        guard found.misses.isEmpty, !found.dataURLs.isEmpty, !Task.isCancelled else { return nil }
        return build(baseHTML: baseHTML, dataURLs: found.dataURLs,
                     preInlineBytes: preInlineBytes, baseIsCIDInlined: baseIsCIDInlined,
                     fontScale: fontScale)
    }

    /// The open's background work: fetch what the cache lacks (the app's
    /// own client, within the caps, never a URL already in flight for this
    /// message) and queue it for storage, with the refusals (rules, unusable
    /// answers, and what falls past the message's byte cap) so the message
    /// can become complete. Network failures are not recorded: retried next
    /// open. The open itself is not changed: WebKit shows the images live.
    /// Returns the body the next open can show, when everything is now
    /// settled, so the caller can keep it with the payload; a cache-only
    /// result marks the message as used.
    static func fetchForNextOpen(messageId: String, accountId: String, baseHTML: String,
                                 preInlineBytes: Int, baseIsCIDInlined: Bool, fontScale: Double,
                                 store: RemoteImageStore?,
                                 transport: RemoteImageTransport) async -> RemoteInlinedBody? {
        let eligible = eligibleURLs(in: baseHTML)
        guard !eligible.isEmpty else { return nil }
        let found = await lookup(messageId: messageId, accountId: accountId, eligible: eligible,
                                 store: store)
        var dataURLs = found.dataURLs
        if found.misses.isEmpty {
            guard !dataURLs.isEmpty else { return nil }
            await store?.noteUsed([messageId])
            return build(baseHTML: baseHTML, dataURLs: dataURLs, preInlineBytes: preInlineBytes,
                         baseIsCIDInlined: baseIsCIDInlined, fontScale: fontScale)
        }
        // Never a URL another resolve of this message is already fetching.
        let room = RemoteImageFetchPolicy.maxMessageBytes - found.cachedBytes
        var mine: [String] = []
        if let store {
            mine = await store.claim(messageId: messageId, urls: found.misses)
        } else {
            mine = found.misses
        }
        var batch = RemoteImageFetcher.Batch()
        if room > 0, !mine.isEmpty {
            batch = await RemoteImageFetcher.fetchAll(mine, byteBudget: room, transport: transport)
        }
        // In document order, within the message's cap.
        var used = found.cachedBytes
        var newImages: [RemoteImageCache.Image] = []
        var refusedKeys: [String] = []
        var settled: Set<String> = []
        let stoppedByCap = room <= 0 || batch.stoppedByBudget
        for url in mine {
            let key = RemoteImageHTML.urlKey(url)
            if batch.refused.contains(url) {
                refusedKeys.append(key)
                settled.insert(url)
                continue
            }
            guard let image = batch.images[url] else {
                // Never started because the cap was reached: a rule too.
                if stoppedByCap, !batch.attempted.contains(url), !Task.isCancelled {
                    refusedKeys.append(key)
                    settled.insert(url)
                }
                continue
            }
            settled.insert(url)
            guard used + image.data.count <= RemoteImageFetchPolicy.maxMessageBytes else {
                refusedKeys.append(key)
                continue
            }
            used += image.data.count
            dataURLs[url] = CIDImageInliner.dataURI(mimeType: image.mimeType, data: image.data)
            newImages.append(RemoteImageCache.Image(urlKey: key, mimeType: image.mimeType,
                                                    data: image.data))
        }
        if let store {
            if !newImages.isEmpty || !refusedKeys.isEmpty {
                await store.remember(RemoteImageCache.Pending(
                    messageId: messageId, accountId: accountId, images: newImages,
                    refused: refusedKeys))
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
            needsNetwork: rewritten.needsNetwork,
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
        /// The first paint waits for the cache check (bounded by
        /// `RemoteImagePaneState.checkDeadline`), so a cached message never
        /// loads live first and then again from the cache.
        case awaitingCacheCheck
    }

    /// The card's choice. A body from the cache is shown whenever images
    /// are allowed, also while it is rebuilt for a newer base (a `cid:`
    /// resolve that landed): the content id follows the body on screen
    /// (`contentID`), so nothing reloads until the rebuilt body arrives.
    static func choice(allowRemoteImages: Bool, remoteBody: RemoteInlinedBody?,
                       awaitingCacheCheck: Bool = false) -> Choice {
        guard allowRemoteImages else { return .base(allowRemoteImages: false) }
        if let remoteBody { return .remote(remoteBody) }
        return awaitingCacheCheck ? .awaitingCacheCheck : .base(allowRemoteImages: true)
    }

    /// The card's `HTMLBodyLoadKey` content id: its `:cid` part comes from
    /// the body actually shown, so a body built on the raw base keeps its id
    /// after the `cid:` resolve lands, and the rebuilt one gets a new id.
    static func contentID(messageId: String, authored: Bool, cidInlined: Bool,
                          remoteBody: RemoteInlinedBody?) -> String {
        let cid = remoteBody?.baseIsCIDInlined ?? cidInlined
        return messageId + (authored ? ":authored" : ":full") + (cid ? ":cid" : "")
            + (remoteBody?.contentSuffix ?? "")
    }

    /// Whether the card's body document has finished loading, for the
    /// background fetch: the key the web view reported (`finished`, cleared
    /// when the body leaves) is the one it loads now. A Load-images click, a
    /// `cid:` base or a font change is a new load to wait for.
    static func bodyLoaded(finished: HTMLBodyLoadKey?, contentID: String,
                           allowRemoteImages: Bool, fontScale: Double) -> Bool {
        finished == HTMLBodyLoadKey(contentID: contentID, allowRemoteImages: allowRemoteImages,
                                    fontScale: fontScale)
    }

    /// What the neighbour pre-render paints (always with the blocked CSP),
    /// or nil to skip: the document the open would claim, never one that
    /// needs the network.
    static func prerender(opensWithRemoteImages: Bool, remoteBody: RemoteInlinedBody?) -> Choice? {
        switch choice(allowRemoteImages: opensWithRemoteImages, remoteBody: remoteBody) {
        case .base(let allow):
            return allow ? nil : .base(allowRemoteImages: false)
        case .remote(let body):
            return body.loadAllowsRemoteImages ? nil : .remote(body)
        case .awaitingCacheCheck:
            return nil
        }
    }
}

/// The reading pane's remote-image decisions for one open conversation,
/// as plain state so every transition is testable without a view.
///
/// Per message: one cache check (the candidates are the same on the stored
/// and the `cid:`-inlined base, so its verdict holds for both), which only
/// the first paint waits for, and at most `checkDeadline`; then either the
/// body from the cache, or the live body plus one background fetch for the
/// next open. The fetch starts only from a mounted body whose own web-view
/// load has ended (`bodyMounted`), so it never competes with the web view's
/// requests to the same hosts, and an oversized body behind its approval
/// placeholder, a collapsed card or a closed pane never fetches; a decision
/// that turns false cancels everything for the message.
struct RemoteImagePaneState: Equatable {
    /// How long the first paint may wait for the cache check before it
    /// paints as without the cache.
    static let checkDeadline: TimeInterval = 0.15

    enum Check: Equatable {
        case running
        case complete
        case incomplete
    }

    enum Step: Equatable {
        /// Images not allowed (any more): stop all work for the message.
        case cancel
        case nothing
        /// Read the cache (keys first) for the first paint.
        case checkCache(baseIsCIDInlined: Bool)
        /// The body from the cache is on screen: mark it used, once.
        case markCachedUsed
        /// A complete cache, rebuilt for a newer base (no network).
        case rebuildFromCache(baseIsCIDInlined: Bool)
        /// The live body is on screen: fetch for the next open, once.
        case fetchForNextOpen(baseIsCIDInlined: Bool)
    }

    private(set) var checks: [String: Check] = [:]
    private var fetches: Set<String> = []
    private var rebuilds: Set<String> = []
    private var cidWaiting: Set<String> = []
    private var marked: Set<String> = []

    private static func key(_ id: String, _ cid: Bool) -> String { id + (cid ? "|cid" : "|raw") }

    /// Whether a card's first paint waits for the cache check now, from the
    /// message's check state (`checks[id]`).
    static func awaitsCacheCheck(check: Check?, allowRemoteImages: Bool, candidateCount: Int,
                                 hasRemoteBody: Bool) -> Bool {
        guard allowRemoteImages, candidateCount > 0, !hasRemoteBody else { return false }
        return check == nil || check == .running
    }

    /// The next step for a card. `bodyMounted`: the HTML body view (not the
    /// waiting placeholder) is on screen and its document's load has ended
    /// (`HTMLBodyView.onLoadFinished`).
    mutating func step(id: String, allowRemoteImages: Bool, bodyMounted: Bool,
                       candidateCount: Int, cidResolveInFlight: Bool, cidInlined: Bool,
                       remoteBody: RemoteInlinedBody?) -> Step {
        guard allowRemoteImages else {
            cancel(id)
            return .cancel
        }
        if let body = remoteBody {
            if body.baseIsCIDInlined == cidInlined {
                guard bodyMounted, marked.insert(id).inserted else { return .nothing }
                return .markCachedUsed
            }
            guard rebuilds.insert(Self.key(id, cidInlined)).inserted else { return .nothing }
            return .rebuildFromCache(baseIsCIDInlined: cidInlined)
        }
        guard candidateCount > 0 else { return .nothing }
        switch checks[id] {
        case nil:
            checks[id] = .running
            return .checkCache(baseIsCIDInlined: cidInlined)
        case .running?:
            return .nothing
        case .complete?:
            guard rebuilds.insert(Self.key(id, cidInlined)).inserted else { return .nothing }
            return .rebuildFromCache(baseIsCIDInlined: cidInlined)
        case .incomplete?:
            guard bodyMounted else { return .nothing }
            if cidResolveInFlight {
                cidWaiting.insert(id)
                return .nothing
            }
            guard fetches.insert(Self.key(id, cidInlined)).inserted else { return .nothing }
            return .fetchForNextOpen(baseIsCIDInlined: cidInlined)
        }
    }

    /// The check ended. Returns whether its body may be shown now (the
    /// check was still running: not cancelled, not past its deadline).
    /// Starts nothing: the next step comes from the mounted body.
    mutating func checkFinished(_ id: String, complete: Bool) -> Bool {
        guard checks[id] == .running else { return false }
        checks[id] = complete ? .complete : .incomplete
        return true
    }

    /// The deadline passed with the check still running: paint as without
    /// the cache; a later result is only kept for the next open.
    mutating func checkTimedOut(_ id: String) {
        if checks[id] == .running { checks[id] = .incomplete }
    }

    /// A `cid:` resolve ended: whether a fetch waited for it.
    mutating func cidFinished(_ id: String) -> Bool {
        cidWaiting.remove(id) != nil
    }

    mutating func cancel(_ id: String) {
        checks.removeValue(forKey: id)
        cidWaiting.remove(id)
        marked.remove(id)
        for cid in [false, true] {
            fetches.remove(Self.key(id, cid))
            rebuilds.remove(Self.key(id, cid))
        }
    }
}
