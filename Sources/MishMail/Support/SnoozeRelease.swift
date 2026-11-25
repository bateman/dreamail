import Foundation

/// When an account is removed, its MishMail snoozes go back to Gmail's
/// Inbox: the snooze date lived only in this Mac's database, so once the
/// account is gone nothing would ever wake them and they would stay archived
/// on Gmail for good. Conversations snoozed in Gmail itself are left to
/// Gmail (`ThreadListQuery.snoozesToRelease`).
///
/// Runs after the purge has committed (`MailStore.removeAccount`): the
/// removal never waits on the network, and a quit during the release still
/// finishes the removal at launch. Only the release is lost then.
enum SnoozeRelease {
    /// The whole release, every call included. What is left counts as not
    /// put back and is reported.
    static let timeoutNanoseconds: UInt64 = 10_000_000_000

    /// Adds INBOX to each Gmail thread id in order. A thread Gmail no longer
    /// has (404) is skipped; any other error (offline, sign-in refused, rate
    /// limit, server error) stops the run, since every later call would fail
    /// the same way. Returns how many were not put back. `reachable` false
    /// (known offline) sends nothing.
    static func release(_ gmailThreadIds: [String], reachable: Bool,
                        timeoutNanoseconds: UInt64 = timeoutNanoseconds,
                        addInbox: @escaping @Sendable (String) async throws -> Void) async -> Int {
        guard !gmailThreadIds.isEmpty else { return 0 }
        guard reachable else { return gmailThreadIds.count }
        let handled = Counter()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for id in gmailThreadIds {
                    if Task.isCancelled { return }
                    do {
                        try await addInbox(id)
                    } catch {
                        if Task.isCancelled { return }
                        guard MessageFetchFailureKind.classify(error) == .notFound else { return }
                    }
                    await handled.add()
                }
            }
            group.addTask { try? await Task.sleep(nanoseconds: timeoutNanoseconds) }
            // Whichever ends first ends the release.
            await group.next()
            group.cancelAll()
        }
        return gmailThreadIds.count - (await handled.value)
    }

    private actor Counter {
        private(set) var value = 0
        func add() { value += 1 }
    }

    /// What the user is told after the removal when some could not be put
    /// back; nil when all were. The removal itself has gone ahead either way.
    static func notReleasedMessage(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        let what = count == 1 ? "1 conversation snoozed in MishMail"
                              : "\(count) conversations snoozed in MishMail"
        return "The account was removed, but MishMail couldn't put \(what) back in the Gmail Inbox. "
            + "In Gmail \(count == 1 ? "it stays" : "they stay") archived: "
            + "find \(count == 1 ? "it" : "them") in All Mail."
    }
}
