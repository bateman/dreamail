import Foundation

/// One account's last refresh of its signatures from Gmail, as Settings
/// shows it. In memory only: a launch always refreshes.
struct SignatureSyncState: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case refreshing
        case done
        /// No network: what is here stays.
        case offline
        /// Gmail answered with an error (sign-in, permission): same.
        case failed
    }

    var status: Status
    /// When the last refresh started (the throttle).
    var lastAttempt: Date
    /// Addresses whose Gmail signature could not be kept, with the reason.
    var unusable: [String: String] = [:]
}

/// When signatures are read from Gmail again. Forced: launch, an account
/// added, "Refresh from Gmail". Throttled to once every `interval` per
/// account: Settings → Signatures shown, a compose window opened.
enum SignatureSyncPolicy {
    static let interval: TimeInterval = 5 * 60

    static func isDue(_ state: SignatureSyncState?, force: Bool, now: Date) -> Bool {
        guard let state else { return true }
        if state.status == .refreshing { return false }
        if force { return true }
        return now.timeIntervalSince(state.lastAttempt) >= interval
            || now < state.lastAttempt
    }
}
