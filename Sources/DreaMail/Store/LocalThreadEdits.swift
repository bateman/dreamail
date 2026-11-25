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

    /// One edit as Gmail will apply it: to the messages the thread held
    /// when it was made. Mail that arrives later is not part of it (Gmail
    /// re-inboxes a thread for a new message).
    struct Edit: Equatable, Sendable {
        let change: RemoteThreadChange
        let at: Date
    }

    private struct Entry {
        let sequence: UInt64
        let edit: Edit
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
    func record(threadIds: [String], change: RemoteThreadChange, at date: Date = Date()) {
        guard !change.isEmpty, !threadIds.isEmpty else { return }
        lock.withLock {
            guard !activePasses.isEmpty else { return }
            sequence += 1
            let entry = Entry(sequence: sequence, edit: Edit(change: change, at: date))
            for id in threadIds {
                edits[id, default: []].append(entry)
            }
        }
    }

    /// The thread was reverted to its messages (Gmail refused an edit, or a
    /// queued edit was dropped): a later derive must not apply its edits.
    ///
    /// All of them, also the ones Gmail accepted: the revert itself puts the
    /// thread back to its message rows, without those accepted edits too.
    /// History replays them from the pass's start id (`SyncEngine`'s kept
    /// first-sync history id), so the overlay and the row stay in step.
    func forget(threadId: String) {
        lock.withLock { _ = edits.removeValue(forKey: threadId) }
    }

    /// The edits made after `mark` to each of `threadIds`, oldest first.
    /// Threads without one are absent.
    func changes(since mark: UInt64, threadIds: Set<String>) -> [String: [Edit]] {
        lock.withLock {
            guard !edits.isEmpty else { return [:] }
            var result: [String: [Edit]] = [:]
            for id in threadIds {
                guard let entries = edits[id] else { continue }
                let later = entries.filter { $0.sequence > mark }.map(\.edit)
                if !later.isEmpty { result[id] = later }
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
