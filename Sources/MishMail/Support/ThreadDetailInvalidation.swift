import Foundation

/// What one content change does to the reading-pane caches.
///
/// `MailStore.applyThreadContentChange` runs this and then hands the result
/// to the parts that live elsewhere (the repository actor, the web-view
/// pre-render slots). Kept pure so the whole fan-out is testable hostless.
enum ThreadDetailInvalidation {
    struct Outcome: Equatable {
        /// For `ThreadDetailRepository.discardStale`.
        var staleness: ThreadContentStaleness
        /// Threads whose pre-rendered views must go; nil means all.
        var affectedThreadIds: Set<String>?
    }

    /// Moves the revisions and drops the mirrored payloads the change made
    /// stale. Nil when nothing moved.
    static func apply(_ change: ThreadContentChange,
                      revisions: inout ThreadContentRevisions,
                      mirror: inout ThreadDetailMirror) -> Outcome? {
        let epochBefore = revisions.epoch
        guard revisions.apply(change) else { return nil }
        // An epoch bump (explicit, or the per-thread map overflowing) makes
        // every older payload stale, not just the named threads.
        let effective: ThreadContentChange =
            revisions.epoch != epochBefore ? .everything : change
        mirror.invalidate(effective)
        if case .threads(let ids) = effective {
            return Outcome(
                staleness: .threads(Dictionary(uniqueKeysWithValues: ids.map {
                    ($0, revisions.revision(of: $0))
                })),
                affectedThreadIds: ids)
        }
        return Outcome(staleness: .before(epoch: revisions.epoch),
                       affectedThreadIds: nil)
    }
}

/// Which thread each parked neighbour pre-render belongs to, so a content
/// change can discard exactly the views painted from stale content (now
/// possibly with resolved inline images) instead of every warm view.
struct PrerenderOwnership {
    /// Parked views are capped at `HTMLWebViewPool.capacity`; a few more
    /// entries cover keys whose view was already claimed or evicted.
    static let capacity = 16

    private(set) var threadByPoolKey: [String: String] = [:]
    private var order: [String] = []

    mutating func record(poolKey: String, threadId: String) {
        if threadByPoolKey.updateValue(threadId, forKey: poolKey) == nil {
            order.append(poolKey)
        }
        while order.count > Self.capacity {
            threadByPoolKey.removeValue(forKey: order.removeFirst())
        }
    }

    /// Pool keys to discard for `threadIds` (nil: every recorded key), and
    /// forgets them.
    mutating func take(threadIds: Set<String>?) -> [String] {
        let keys = order.filter { key in
            guard let threadIds else { return true }
            return threadByPoolKey[key].map(threadIds.contains) ?? false
        }
        for key in keys { threadByPoolKey.removeValue(forKey: key) }
        order.removeAll { threadByPoolKey[$0] == nil }
        return keys
    }
}
