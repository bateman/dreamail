import Foundation
import GRDB

/// Gmail label colors the app has just written (or is writing), so a label
/// sync that fetched the list before the write landed cannot put the old
/// color back. In memory only, keyed by label row id; an entry lives while
/// its write is in flight and for `grace` after, and goes as soon as a sync
/// sees Gmail agree. Nothing here outlives the app, and removing an account
/// drops its entries (`forgetAccount`) for good: an edit still in flight
/// cannot put one back.
final class PendingLabelColorEdits: @unchecked Sendable {
    static let shared = PendingLabelColorEdits()

    /// How long a confirmed color is held against older sync answers.
    static let grace: TimeInterval = 120

    private struct Hold {
        var colors: LabelColors
        var expires: Date
    }

    private struct Entry {
        var colors: LabelColors
        /// nil while the write is in flight.
        var expires: Date?
        /// The confirmed hold this edit replaced, restored if it fails.
        var prior: Hold?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Starts an edit; false when one is already in flight for the label.
    func begin(_ id: String, colors: LabelColors) -> Bool {
        lock.withLock {
            let current = entries[id]
            if let current, current.expires == nil { return false }
            let prior = current.flatMap { e in e.expires.map { Hold(colors: e.colors, expires: $0) } }
            entries[id] = Entry(colors: colors, expires: nil, prior: prior)
            return true
        }
    }

    /// The write landed: hold Gmail's answer for `grace`. Only an edit
    /// still in flight is confirmed, so nothing comes back after
    /// `forgetAccount`.
    func confirm(_ id: String, colors: LabelColors, now: Date) {
        lock.withLock {
            guard let e = entries[id], e.expires == nil else { return }
            entries[id] = Entry(colors: colors, expires: now.addingTimeInterval(Self.grace), prior: nil)
        }
    }

    /// The write failed: back to the hold it replaced, if any.
    func cancel(_ id: String) {
        lock.withLock {
            guard let e = entries[id], e.expires == nil else { return }
            if let p = e.prior {
                entries[id] = Entry(colors: p.colors, expires: p.expires, prior: nil)
            } else {
                entries.removeValue(forKey: id)
            }
        }
    }

    func forgetAccount(_ accountId: String) {
        let prefix = accountId + ":"
        lock.withLock { entries = entries.filter { !$0.key.hasPrefix(prefix) } }
    }

    /// The Gmail colors a sync should store for a label: the held ones while
    /// an edit is pending, else nil (store what Gmail sent). Drops a
    /// confirmed entry once Gmail sends the same colors or it expires.
    func held(_ id: String, fetched: LabelColors, now: Date) -> LabelColors? {
        lock.withLock {
            guard let e = entries[id] else { return nil }
            if let expires = e.expires, expires <= now || e.colors == fetched {
                entries.removeValue(forKey: id)
                return nil
            }
            return e.colors
        }
    }
}

/// Changes a user label's color on Gmail (`labels.patch`): checks it
/// first, shows it at once, then keeps Gmail's answer or puts the old
/// color back if the call fails. The Mac-only color (`LabelRow.color`,
/// DEC-023) is not touched and still wins on display. A color outside
/// Gmail's palette cannot be asked for: `GmailLabelColor` refuses it.
enum GmailLabelColorEdit {
    enum Failure: LocalizedError, Equatable {
        case systemLabel
        case inFlight
        case unknownLabel
        /// Gmail answered but kept a different color.
        case notApplied

        var errorDescription: String? {
            switch self {
            case .systemLabel: return "System labels have no color in Gmail."
            case .inFlight: return "That label's color is still being saved to Gmail."
            case .unknownLabel: return "That label is no longer in Gmail."
            case .notApplied: return "Gmail didn't apply the color change."
            }
        }
    }

    /// What the app does once an edit is over.
    enum Outcome: Equatable {
        case saved
        /// Gmail refused the sign-in's access (403, not a rate limit):
        /// flag the account for reauthorization.
        case reauthorize
        case banner(String)
        /// The account was removed meanwhile: say nothing.
        case silent
    }

    static func outcome(_ error: Error?, accountKnown: Bool) -> Outcome {
        guard accountKnown else { return .silent }
        guard let error else { return .saved }
        if case GmailError.http(403, let body) = error, !MessageFetchFailureKind.isRateLimitBody(body) {
            return .reauthorize
        }
        if let failure = error as? Failure { return .banner(failure.errorDescription ?? "") }
        return .banner("Couldn't change the label color on Gmail: \(error.localizedDescription)")
    }

    typealias Patch = (_ gmailLabelId: String, _ color: GmailLabelColor?) async throws -> GLabel

    /// The Gmail colors a label row stores for an API answer.
    static func colors(of label: GLabel) -> LabelColors {
        LabelColors(background: LabelRGB.normalizedHex(label.color?.backgroundColor),
                    text: LabelRGB.normalizedHex(label.color?.textColor))
    }

    /// Sets (or, with nil, removes) the label's Gmail color. Throws
    /// `Failure` before any call for a system label or while another edit
    /// of it is in flight. The new color is stored, then `didStore` runs
    /// (the app shows it), then Gmail is called; on a failed call the
    /// previous colors are restored and the error rethrown.
    static func apply(_ target: GmailLabelColor?,
                      labelRowId id: String,
                      db: any DatabaseWriter,
                      pending: PendingLabelColorEdits = .shared,
                      now: () -> Date = { Date() },
                      didStore: () async -> Void = {},
                      patch: Patch) async throws {
        let wanted = target?.colors ?? .none
        // Read, claim and write in one transaction, so `before` is what the
        // optimistic write replaced and no sync lands in between.
        let (gmailLabelId, before) = try await db.write { db -> (String, LabelColors) in
            guard let row = try LabelRow.fetchOne(db, key: id) else { throw Failure.unknownLabel }
            guard row.type == "user" else { throw Failure.systemLabel }
            guard pending.begin(id, colors: wanted) else { throw Failure.inFlight }
            try store(db, wanted, id: id)
            return (row.gmailLabelId, LabelColors(background: row.gmailBackgroundColor,
                                                  text: row.gmailTextColor))
        }
        await didStore()
        let answer: GLabel
        do {
            answer = try await patch(gmailLabelId, target)
        } catch {
            pending.cancel(id)
            // Only over our own write: a sync may have stored newer colors.
            try? await db.write { db in
                try db.execute(sql: """
                    UPDATE label SET gmailBackgroundColor = ?, gmailTextColor = ?
                    WHERE id = ? AND gmailBackgroundColor IS ? AND gmailTextColor IS ?
                    """, arguments: [before.background, before.text, id, wanted.background, wanted.text])
            }
            throw error
        }
        let confirmed = colors(of: answer)
        try? await db.write { db in try store(db, confirmed, id: id) }
        pending.confirm(id, colors: confirmed, now: now())
        if confirmed != wanted { throw Failure.notApplied }
    }

    private static func store(_ db: Database, _ colors: LabelColors, id: String) throws {
        try db.execute(sql: "UPDATE label SET gmailBackgroundColor = ?, gmailTextColor = ? WHERE id = ?",
                       arguments: [colors.background, colors.text, id])
    }
}
