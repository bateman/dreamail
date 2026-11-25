import Foundation

/// Thread edits the user made while a sync pass was running.
///
/// An optimistic edit (archive, star, read, label, trash, snooze) rewrites
/// the thread row only; message rows keep Gmail's last known labels until
/// history reports the edit (see `OptimisticThreadWrite`). A backfill
/// (first sync, a wider "Keep mail from", the starred pull) re-derives a
/// thread whenever a later page brings another of its messages, and the
/// messages it derives from were downloaded before Gmail took the edit. Left
/// alone, that derive puts the old labels back: an archived conversation
/// returns to the Inbox until the next pass.
///
/// So each pass registers here, every edit made while any pass runs is
/// recorded as the Gmail change it sends, and the backfill derive applies
/// the changes made since its own pass began to the messages before deriving
/// — the state Gmail will hold once the edit lands. Entries no running pass
/// can need are dropped, so the registry is empty between passes. Memory
/// only: it holds thread ids and label ids, never content.
final class LocalThreadEdits: @unchecked Sendable {
    static let shared = LocalThreadEdits()

    private struct Entry {
        let sequence: UInt64
        let change: RemoteThreadChange
    }

    private let lock = NSLock()
    private var sequence: UInt64 = 0
    /// Marks of the passes running now (a mark can repeat: two engines may
    /// start between two edits).
    private var activePasses: [UInt64] = []
    private var edits: [String: [Entry]] = [:]

    /// A pass starts: edits recorded from now on apply to it. Pair with
    /// `endPass`.
    func beginPass() -> UInt64 {
        lock.withLock {
            activePasses.append(sequence)
            return sequence
        }
    }

    func endPass(_ mark: UInt64) {
        lock.withLock {
            if let index = activePasses.firstIndex(of: mark) {
                activePasses.remove(at: index)
            }
            prune()
        }
    }

    /// Records one edit per thread. Ignored while no pass runs: nothing
    /// could re-derive the threads from stale messages.
    func record(threadIds: [String], change: RemoteThreadChange) {
        guard !change.isEmpty, !threadIds.isEmpty else { return }
        lock.withLock {
            guard !activePasses.isEmpty else { return }
            sequence += 1
            for id in threadIds {
                edits[id, default: []].append(Entry(sequence: sequence, change: change))
            }
        }
    }

    /// Gmail refused the edit and the thread was reverted to its messages:
    /// a later derive must not apply it again.
    func forget(threadId: String) {
        lock.withLock { _ = edits.removeValue(forKey: threadId) }
    }

    /// The edits made after `mark` to each of `threadIds`, folded in order
    /// into one change per thread. Threads without one are absent.
    func changes(since mark: UInt64, threadIds: Set<String>) -> [String: RemoteThreadChange] {
        lock.withLock {
            guard !edits.isEmpty else { return [:] }
            var result: [String: RemoteThreadChange] = [:]
            for id in threadIds {
                guard let entries = edits[id] else { continue }
                var folded: RemoteThreadChange?
                for entry in entries where entry.sequence > mark {
                    folded = folded.map { $0.merged(with: entry.change) } ?? entry.change
                }
                if let folded, !folded.isEmpty { result[id] = folded }
            }
            return result
        }
    }

    /// DEC-019: nothing of a removed account stays in memory. Thread ids
    /// are `accountId:gmailThreadId`.
    func forget(accountId: String) {
        let prefix = accountId + ":"
        lock.withLock {
            edits = edits.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    var isEmpty: Bool { lock.withLock { edits.isEmpty } }

    /// Keeps only what a running pass can still ask for.
    private func prune() {
        guard let oldest = activePasses.min() else {
            edits.removeAll()
            return
        }
        for (id, entries) in edits {
            let kept = entries.filter { $0.sequence > oldest }
            edits[id] = kept.isEmpty ? nil : kept
        }
    }
}
