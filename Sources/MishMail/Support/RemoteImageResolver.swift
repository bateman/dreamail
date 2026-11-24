import Foundation

/// A message body with its remote images (those already known) inlined as
/// `data:` URLs, plus the prep built from it off the main actor.
///
/// - `partial`: built from the cache alone while some images were never
///   fetched; shown with the blocked CSP (the missing ones stay blank until
///   the open fetches them). The neighbour pre-render paints this.
/// - `final`: every candidate was resolved or attempted. Shown with the
///   blocked CSP when `needsNetwork` is false (nothing left to fetch, so a
///   blocked pre-render of the same body can be claimed), else with the
///   allowed CSP so what the app could not cache loads live as before.
struct RemoteInlinedBody: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case partial
        case final
    }

    var html: String
    var prep: MessageHTMLPrep
    var phase: Phase
    /// Something in `html` can still load a remote image.
    var needsNetwork: Bool
    /// Candidate occurrences rewritten to `data:`.
    var inlinedCount: Int
    /// Built on the `cid:`-inlined body rather than the stored one.
    var baseIsCIDInlined: Bool

    /// Appended to the card's content id (`HTMLBodyLoadKey`): a partial body
    /// and the final one are different documents.
    var contentSuffix: String {
        phase == .final ? ":rimg" : ":rimg-p\(inlinedCount)"
    }

    /// The CSP variant the card loads this body with.
    var loadAllowsRemoteImages: Bool { phase == .final && needsNetwork }
}

/// Builds `RemoteInlinedBody`s: from the cache only (`cachedBody`, used by
/// the prefetch, the pre-render and the open's first step), or from the
/// cache plus the app's own fetch of what is missing (`resolve`, used only
/// when a message is open and its remote images are allowed). Never logs.
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

    /// The body as far as the cache goes, with no network. Nil when it has
    /// no candidate, or nothing cached while some are still to fetch (the
    /// stored body, blocked, is then the same picture).
    static func cachedBody(messageId: String, accountId: String, baseHTML: String,
                           preInlineBytes: Int, baseIsCIDInlined: Bool, fontScale: Double,
                           store: RemoteImageStore?) async -> RemoteInlinedBody? {
        guard let found = await lookup(messageId: messageId, accountId: accountId,
                                       baseHTML: baseHTML, store: store),
              !found.dataURLs.isEmpty || found.misses.isEmpty,
              !Task.isCancelled else { return nil }
        return build(baseHTML: baseHTML, dataURLs: found.dataURLs,
                     phase: found.misses.isEmpty ? .final : .partial,
                     preInlineBytes: preInlineBytes, baseIsCIDInlined: baseIsCIDInlined,
                     fontScale: fontScale)
    }

    /// The open's resolve: the cache first; then, when images are missing,
    /// `onPartial` with what the cache had (only if it had any), the app's
    /// fetch of the rest, the new images queued for storage, and the final
    /// body. A cache-only result marks the message as used.
    static func resolve(messageId: String, accountId: String, baseHTML: String,
                        preInlineBytes: Int, baseIsCIDInlined: Bool, fontScale: Double,
                        store: RemoteImageStore?, transport: RemoteImageTransport,
                        onPartial: @Sendable (RemoteInlinedBody) async -> Void = { _ in })
        async -> RemoteInlinedBody? {
        guard let found = await lookup(messageId: messageId, accountId: accountId,
                                       baseHTML: baseHTML, store: store) else { return nil }
        var dataURLs = found.dataURLs
        if found.misses.isEmpty {
            if !dataURLs.isEmpty { await store?.noteUsed([messageId]) }
            return build(baseHTML: baseHTML, dataURLs: dataURLs, phase: .final,
                         preInlineBytes: preInlineBytes, baseIsCIDInlined: baseIsCIDInlined,
                         fontScale: fontScale)
        }
        if !dataURLs.isEmpty {
            await onPartial(build(baseHTML: baseHTML, dataURLs: dataURLs, phase: .partial,
                                  preInlineBytes: preInlineBytes,
                                  baseIsCIDInlined: baseIsCIDInlined, fontScale: fontScale))
        }
        let fetched = await RemoteImageFetcher.fetchAll(found.misses, transport: transport)
        // In document order, within the message's cap.
        var used = found.cachedBytes
        var newImages: [RemoteImageCache.Image] = []
        var failedKeys: [String] = []
        for url in found.misses {
            let key = RemoteImageHTML.urlKey(url)
            guard let image = fetched[url] else {
                failedKeys.append(key)
                continue
            }
            guard used + image.data.count <= RemoteImageFetchPolicy.maxMessageBytes else {
                failedKeys.append(key)
                continue
            }
            used += image.data.count
            dataURLs[url] = CIDImageInliner.dataURI(mimeType: image.mimeType, data: image.data)
            newImages.append(RemoteImageCache.Image(urlKey: key, mimeType: image.mimeType,
                                                    data: image.data))
        }
        if let store {
            // A cancelled open is not a refusal: those URLs are tried again.
            if !Task.isCancelled, !failedKeys.isEmpty {
                await store.noteFailed(messageId: messageId, urlKeys: failedKeys)
            }
            if !newImages.isEmpty {
                await store.remember(RemoteImageCache.Pending(
                    messageId: messageId, accountId: accountId, images: newImages))
            }
        }
        guard !Task.isCancelled else { return nil }
        return build(baseHTML: baseHTML, dataURLs: dataURLs, phase: .final,
                     preInlineBytes: preInlineBytes, baseIsCIDInlined: baseIsCIDInlined,
                     fontScale: fontScale)
    }

    /// The reading pane's entry point for one open message. `allowed` is the
    /// card's `RemoteImagePolicy.autoLoads` decision (opt-ins included):
    /// when false nothing at all happens (no cache read, no request).
    /// `preInlineBytes`: the stored body's size (the oversized-body gate
    /// keys on it, not on the inlined one).
    static func resolveIfAllowed(
        _ allowed: Bool, messageId: String, accountId: String, baseHTML: String,
        preInlineBytes: Int, baseIsCIDInlined: Bool, fontScale: Double,
        store: RemoteImageStore?, transport: RemoteImageTransport,
        onPartial: @escaping @Sendable (RemoteInlinedBody) async -> Void
    ) async -> RemoteInlinedBody? {
        guard allowed else { return nil }
        return await resolve(
            messageId: messageId, accountId: accountId, baseHTML: baseHTML,
            preInlineBytes: preInlineBytes, baseIsCIDInlined: baseIsCIDInlined,
            fontScale: fontScale, store: store, transport: transport, onPartial: onPartial)
    }

    /// Rewrite and prep: whole-body string work, off the main actor.
    static func build(baseHTML: String, dataURLs: [String: String],
                      phase: RemoteInlinedBody.Phase, preInlineBytes: Int,
                      baseIsCIDInlined: Bool, fontScale: Double) -> RemoteInlinedBody {
        let rewritten = RemoteImageHTML.rewrite(baseHTML, dataURLs: dataURLs)
        let prep = MessageHTMLPrepBuilder.cidInlinedPrep(
            inlinedHTML: rewritten.html, preInlineBytes: preInlineBytes, fontScale: fontScale)
        return RemoteInlinedBody(
            html: rewritten.html, prep: prep, phase: phase,
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
        /// gives: today's behaviour.
        case base(allowRemoteImages: Bool)
        /// The stored body with remote images blocked while the open fetches
        /// them (no cached body yet).
        case baseBlockedWhileResolving
        case remote(RemoteInlinedBody)
    }

    /// The card's choice. `remoteBody` is used only when remote images are
    /// allowed for this message and it was built on the same base.
    static func choice(allowRemoteImages: Bool, remoteBody: RemoteInlinedBody?,
                       cidInlined: Bool, remoteCandidateCount: Int) -> Choice {
        guard allowRemoteImages else { return .base(allowRemoteImages: false) }
        if let remoteBody, remoteBody.baseIsCIDInlined == cidInlined {
            return .remote(remoteBody)
        }
        return remoteCandidateCount > 0 ? .baseBlockedWhileResolving
            : .base(allowRemoteImages: true)
    }

    /// What the neighbour pre-render paints (always with the blocked CSP),
    /// or nil to skip: the document the open would claim, never one that
    /// needs the network.
    static func prerender(opensWithRemoteImages: Bool, remoteBody: RemoteInlinedBody?,
                          cidInlined: Bool, remoteCandidateCount: Int) -> Choice? {
        switch choice(allowRemoteImages: opensWithRemoteImages, remoteBody: remoteBody,
                      cidInlined: cidInlined, remoteCandidateCount: remoteCandidateCount) {
        case .base(let allow):
            return allow ? nil : .base(allowRemoteImages: false)
        case .baseBlockedWhileResolving:
            return .baseBlockedWhileResolving
        case .remote(let body):
            return body.loadAllowsRemoteImages ? nil : .remote(body)
        }
    }
}
