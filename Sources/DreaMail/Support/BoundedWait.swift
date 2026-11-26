import Foundation

/// Waits for a callback-style operation, but never longer than a limit.
/// Not a task group: a group returns only when every child has finished,
/// and a bridged callback ignores cancellation, so a daemon that never
/// answers would hang the caller.
enum BoundedWait {
    /// Starts `operation`, which must call `done` when it finishes, and
    /// returns when it does or after `timeout`, whichever is first. A late
    /// `done` is ignored.
    static func run(
        timeout: Duration,
        operation: (_ done: @escaping @Sendable () -> Void) -> Void
    ) async {
        let (finished, signal) = AsyncStream<Void>.makeStream()
        operation { signal.yield() }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            signal.yield()
        }
        for await _ in finished { break }
        timer.cancel()
    }
}
