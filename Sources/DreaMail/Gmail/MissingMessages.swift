import Foundation

/// Messages a history catch-up could not download, kept per account so they
/// are not lost for good once the history id moves past them.
///
/// A `messages.get` that answers 404, or a permanent per-message 4xx, used
/// to be dropped while the pass went on. Gmail can answer 404 for a message
/// that exists a moment later, and a 4xx can be transient on Google's side.
/// Each id is retried on later passes with a growing wait; a 404 is final
/// only when a second 404 comes at least `notFoundGrace` after the first.
/// Other failures are retried (with the wait capped) until they succeed.
/// Holds Gmail message ids and dates only: no mail data. Pure — tested.
struct MissingMessages: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var firstSeen: Date
        var lastTried: Date
        var attempts: Int
        var lastWasNotFound: Bool
    }

    private(set) var entries: [String: Entry] = [:]

    /// At most this many ids are kept; past it the oldest give way.
    static let maxEntries = 500
    /// A 404 is final only once it repeats this long after the first.
    static let notFoundGrace: TimeInterval = 10 * 60
    /// Wait before the first retry, doubled per attempt up to `maxBackoff`.
    static let firstBackoff: TimeInterval = 60
    static let maxBackoff: TimeInterval = 6 * 3600
    /// Ids retried per pass.
    static let retryBatch = 50
    /// A failure other than 404 is retried this long, then dropped, so the
    /// count shown cannot stay up for ever.
    static let maxAge: TimeInterval = 30 * 86_400

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    /// What the status line counts: ids whose last failure was not a 404.
    /// A 404 is the normal answer for a message deleted between the
    /// history read and its download (a draft saved again, a message
    /// deleted at once); those wait silently for their second answer.
    var undownloadedCount: Int { entries.values.filter { !$0.lastWasNotFound }.count }

    /// Gmail reported these deleted (`messagesDeleted`): nothing to retry.
    mutating func forget(_ ids: some Sequence<String>) {
        for id in ids { entries.removeValue(forKey: id) }
    }

    /// Drops ids first seen more than `maxAge` ago.
    mutating func expire(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.firstSeen) < Self.maxAge }
    }

    /// A catch-up could not download `ids` (`notFound`: Gmail answered 404).
    mutating func noteMissed(_ ids: [String], notFound: Bool, now: Date) {
        for id in ids {
            if var entry = entries[id] {
                entry.lastTried = now
                entry.attempts += 1
                entry.lastWasNotFound = notFound
                entries[id] = entry
            } else {
                entries[id] = Entry(firstSeen: now, lastTried: now, attempts: 1,
                                    lastWasNotFound: notFound)
            }
        }
        trim()
    }

    static func backoff(attempts: Int) -> TimeInterval {
        let doublings = max(0, min(attempts - 1, 20))
        return min(firstBackoff * pow(2, Double(doublings)), maxBackoff)
    }

    /// Ids whose wait has passed, oldest first, at most `limit`.
    func due(now: Date, limit: Int = retryBatch) -> [String] {
        entries
            .filter { now.timeIntervalSince($0.value.firstSeen) < Self.maxAge }
            .filter { now.timeIntervalSince($0.value.lastTried) >= Self.backoff(attempts: $0.value.attempts) }
            .sorted { ($0.value.firstSeen, $0.key) < ($1.value.firstSeen, $1.key) }
            .prefix(limit)
            .map(\.key)
    }

    /// The outcome of a retry: `stored` ids are done (or were already
    /// stored), `notFound` answered 404, `failed` failed otherwise.
    mutating func resolve(stored: [String], notFound: [String], failed: [String], now: Date) {
        for id in stored { entries.removeValue(forKey: id) }
        for id in notFound {
            guard let entry = entries[id] else { continue }
            if entry.lastWasNotFound, now.timeIntervalSince(entry.firstSeen) >= Self.notFoundGrace {
                entries.removeValue(forKey: id)   // gone in Gmail: final
            } else {
                noteMissed([id], notFound: true, now: now)
            }
        }
        for id in failed where entries[id] != nil {
            noteMissed([id], notFound: false, now: now)
        }
        expire(now: now)
    }

    private mutating func trim() {
        guard entries.count > Self.maxEntries else { return }
        let oldest = entries.sorted { ($0.value.firstSeen, $0.key) < ($1.value.firstSeen, $1.key) }
            .prefix(entries.count - Self.maxEntries).map(\.key)
        for id in oldest { entries.removeValue(forKey: id) }
    }

    // MARK: - Storage (per account, removed with the account)

    static func defaultsKey(accountId: String) -> String {
        "sync.missingMessages.v1.\(accountId)"
    }

    static func load(accountId: String, defaults: UserDefaults = .standard) -> MissingMessages {
        guard let data = defaults.data(forKey: defaultsKey(accountId: accountId)),
              let value = try? JSONDecoder().decode(MissingMessages.self, from: data)
        else { return MissingMessages() }
        return value
    }

    func save(accountId: String, defaults: UserDefaults = .standard) {
        let key = Self.defaultsKey(accountId: accountId)
        if isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: key)
        }
    }
}
