import Foundation
import GRDB

/// Gmail label colors the app has just written (or is writing), so a label
/// sync that fetched the list before the write landed cannot put the old
/// color back. In memory only, keyed by label row id; an entry lives while
/// its write is in flight and for `grace` after, and goes as soon as a sync
/// sees Gmail agree. Nothing here outlives the app, and removing an account
/// drops its entries (`forgetAccount`).
final class PendingLabelColorEdits: @unchecked Sendable {
    static let shared = PendingLabelColorEdits()

    /// How long a confirmed color is held against older sync answers.
    static let grace: TimeInterval = 120

    private struct Entry {
        var colors: LabelColors
        /// nil while the write is in flight.
        var expires: Date?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Starts an edit; false when one is already in flight for the label.
    func begin(_ id: String, colors: LabelColors) -> Bool {
        lock.withLock {
            if let e = entries[id], e.expires == nil { return false }
            entries[id] = Entry(colors: colors, expires: nil)
            return true
        }
    }

    /// The write landed: hold Gmail's answer for `grace`.
    func confirm(_ id: String, colors: LabelColors, now: Date) {
        lock.withLock { entries[id] = Entry(colors: colors, expires: now.addingTimeInterval(Self.grace)) }
    }

    func cancel(_ id: String) {
        lock.withLock { _ = entries.removeValue(forKey: id) }
    }

    func forgetAccount(_ accountId: String) {
        let prefix = accountId + ":"
        lock.withLock { entries = entries.filter { !$0.key.hasPrefix(prefix) } }
    }

    func isInFlight(_ id: String) -> Bool {
        lock.withLock { entries[id].map { $0.expires == nil } ?? false }
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
/// DEC-023) is not touched and still wins on display.
enum GmailLabelColorEdit {
    enum Failure: LocalizedError, Equatable {
        case systemLabel
        case offPalette
        case inFlight
        case unknownLabel
        /// Gmail answered but kept a different color.
        case notApplied

        var errorDescription: String? {
            switch self {
            case .systemLabel: return "System labels have no color in Gmail."
            case .offPalette: return "Gmail only accepts colors from its own palette."
            case .inFlight: return "That label's color is still being saved to Gmail."
            case .unknownLabel: return "That label is no longer in Gmail."
            case .notApplied: return "Gmail didn't apply the color change."
            }
        }
    }

    /// What the banner says when a change fails. A 403 that is not a rate
    /// limit means Gmail refused the sign-in's access (scope or consent).
    static func errorMessage(_ error: Error) -> String {
        if case GmailError.http(403, let body) = error, !MessageFetchFailureKind.isRateLimitBody(body) {
            return "Gmail refused the color change. Reauthorize the account in Settings → Accounts and try again."
        }
        if let failure = error as? Failure { return failure.errorDescription ?? "" }
        return "Couldn't change the label color on Gmail: \(error.localizedDescription)"
    }

    typealias Patch = (_ gmailLabelId: String, _ color: GmailLabelColor?) async throws -> GLabel

    /// The Gmail colors a label row stores for an API answer.
    static func colors(of label: GLabel) -> LabelColors {
        LabelColors(background: LabelRGB.normalizedHex(label.color?.backgroundColor),
                    text: LabelRGB.normalizedHex(label.color?.textColor))
    }

    /// Sets (or, with nil, removes) the label's Gmail color. Throws
    /// `Failure` before any call for a system label or a color outside
    /// Gmail's palette; on a failed call the stored colors are restored and
    /// the error rethrown.
    static func apply(_ requested: LabelColors?,
                      labelRowId id: String,
                      db: any DatabaseWriter,
                      pending: PendingLabelColorEdits = .shared,
                      now: () -> Date = { Date() },
                      patch: Patch) async throws {
        guard let row = try await db.read({ try LabelRow.fetchOne($0, key: id) }) else {
            throw Failure.unknownLabel
        }
        guard row.type == "user" else { throw Failure.systemLabel }
        let target: GmailLabelColor?
        if let requested {
            guard let color = GmailLabelColor(background: requested.background, text: requested.text) else {
                throw Failure.offPalette
            }
            target = color
        } else {
            target = nil
        }
        let wanted = target?.colors ?? .none
        let before = LabelColors(background: row.gmailBackgroundColor, text: row.gmailTextColor)
        guard pending.begin(id, colors: wanted) else { throw Failure.inFlight }

        let answer: GLabel
        do {
            try await store(wanted, id: id, db: db)
            answer = try await patch(row.gmailLabelId, target)
        } catch {
            pending.cancel(id)
            try? await store(before, id: id, db: db)
            throw error
        }
        let confirmed = colors(of: answer)
        try? await store(confirmed, id: id, db: db)
        pending.confirm(id, colors: confirmed, now: now())
        if confirmed != wanted { throw Failure.notApplied }
    }

    private static func store(_ colors: LabelColors, id: String, db: any DatabaseWriter) async throws {
        try await db.write { db in
            try db.execute(sql: "UPDATE label SET gmailBackgroundColor = ?, gmailTextColor = ? WHERE id = ?",
                           arguments: [colors.background, colors.text, id])
        }
    }
}
