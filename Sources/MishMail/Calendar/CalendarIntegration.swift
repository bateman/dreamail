import Foundation
import GRDB
import Observation
import Security

/// One account's Calendar connection, as Settings and the invitation card
/// show it.
enum CalendarAccountStatus: Equatable, Sendable {
    /// The build has no Calendar integration: nothing is shown.
    case off
    case notConnected
    case connected(CalendarGrant)
    /// Connected once, but Google no longer accepts the grant (revoked or
    /// expired). Reconnecting keeps the chosen calendars.
    case needsConsent

    var isConnected: Bool { grant != nil }

    var grant: CalendarGrant? {
        if case .connected(let grant) = self { return grant }
        return nil
    }
}

/// What the invitation card knows about the user's Google Calendar for one
/// invitation. Kept in memory by the card; nothing of it is stored.
enum CalendarInviteCheck: Equatable, Sendable {
    case off
    case notConnected
    case needsConsent
    case checking
    case offline
    /// A Calendar error, as a message without any response body.
    case failed(String)
    case ready(CalendarInviteFindings)

    var findings: CalendarInviteFindings? {
        if case .ready(let findings) = self { return findings }
        return nil
    }

    /// What the card shows once the account's status changed under it: a
    /// disconnect or a refused grant drops findings it still holds.
    func current(_ status: CalendarAccountStatus) -> CalendarInviteCheck {
        guard case .ready = self else { return self }
        return status.isConnected ? self : Self.unusable(status)
    }

    /// The state for an account that cannot be checked.
    static func unusable(_ status: CalendarAccountStatus) -> CalendarInviteCheck {
        switch status {
        case .off: return .off
        case .notConnected, .connected: return .notConnected
        case .needsConsent: return .needsConsent
        }
    }
}

/// The answer to "am I free, and where is this event" for one invitation.
struct CalendarInviteFindings: Equatable, Sendable {
    /// Nil when the invitation has no usable time, no calendar is chosen,
    /// or it is too long to check (`availabilitySkipped`).
    var availability: CalendarAvailabilityResult?
    /// The invitation lasts longer than `CalendarIntegration.maxCheckedSpan`.
    var availabilitySkipped: Bool = false
    /// The invitation's event in the user's Google Calendar; nil when it is
    /// on none of the calendars looked at.
    var event: CalendarInviteEventRecord?
    var grant: CalendarGrant

    /// Where Accept / Decline / Maybe goes (`CalendarRSVPRoute`).
    func route(for facts: CalendarInviteFacts) -> CalendarRSVPRoute {
        CalendarRSVPRoute.route(for: facts, event: event, canWrite: grant.canWriteEvents)
    }

    /// "Add to Calendar" is offered only for an invitation whose organizer
    /// sent it: a forwarded or forged one must not create an event.
    func canAddToCalendar(_ facts: CalendarInviteFacts, organizerIsSender: Bool) -> Bool {
        organizerIsSender
            && CalendarInvitePlan.canAddToCalendar(facts, event: event, canWrite: grant.canWriteEvents)
    }
}

/// The text under the RSVP buttons: where the answer goes, from whom.
/// Pure, so each route's wording is tested. The e-mail always goes first
/// (`CalendarIntegration.answer`); the calendar follows only when it holds
/// this very event.
enum CalendarAnswerNote {
    static func text(route: CalendarRSVPRoute, accountId: String, from: String,
                     organizer: String) -> String {
        if case .calendarAndEmail = route {
            return "Reply from \(from) goes to \(organizer); the answer will also be saved in Google Calendar (\(accountId))"
        }
        return "Reply from \(from) goes to \(organizer)"
    }
}

/// What answering an invitation did (`CalendarIntegration.answer`).
struct CalendarAnswerResult: Equatable, Sendable {
    var emailSent: Bool
    var calendarWritten: Bool
    /// The e-mail went but the calendar was not updated: why, without any
    /// response body. Nil when nothing was to be written.
    var calendarFailure: String?
    /// Google no longer has the event: the card looks it up again.
    var eventGone: Bool

    static let notSent = CalendarAnswerResult(emailSent: false, calendarWritten: false,
                                              calendarFailure: nil, eventGone: false)
}

/// The Calendar integration as the app's UI sees it: connect and disconnect
/// one account, choose its calendars, check an invitation, answer it, add it
/// to the calendar. The only door from outside the Calendar folder.
///
/// Stores nothing beyond `CalendarStore`'s rows (the grant and the chosen
/// calendars). Where each invitation's event is (or that it is on no
/// calendar) is kept in memory for `locateCacheLifetime`, by account and
/// iCalendar UID, so reopening a message does not ask every chosen calendar
/// again; account removal (`forget`) and disconnect clear it. A rate limit
/// pauses the account's Calendar requests for as long as Google asks. Logs
/// nothing. With the switch off every method refuses before any request,
/// Keychain read or browser.
@MainActor
@Observable
final class CalendarIntegration {
    static let shared = CalendarIntegration(dependencies: .live)

    struct Dependencies {
        var enabled: Bool
        var database: @MainActor () -> any DatabaseWriter
        var steps: CalendarAuthorization.Steps
        var transport: CalendarTransport
        var readRefreshToken: CalendarTokenSource.ReadRefreshToken
        var refresh: CalendarTokenSource.Refresh
        /// Deletes the account's Calendar refresh token; the Keychain status.
        var deleteRefreshToken: @Sendable (_ accountId: String) -> OSStatus

        static let live = Dependencies(
            enabled: CalendarFeatures.isEnabled,
            database: { AppDatabase.shared.dbPool },
            steps: .live,
            transport: .live,
            readRefreshToken: { Keychain.read($0) },
            refresh: { try await OAuthService.refreshAccessToken(refreshToken: $0) },
            deleteRefreshToken: {
                Keychain.deleteReportingStatus(CalendarAuthorization.keychainKey(accountId: $0))
            })
    }

    /// Granted scopes by account, read from the database.
    private(set) var grants: [String: CalendarGrant] = [:]
    /// The chosen calendars by account, read from the database.
    private(set) var chosen: [String: [CalendarSourceRecord]] = [:]
    /// Accounts whose grant Google refused since launch. In memory only.
    private(set) var needingConsent: Set<String> = []
    /// Accounts whose Calendar consent is open in the browser.
    private(set) var connecting: Set<String> = []
    @ObservationIgnored private var loaded: Set<String> = []

    private let deps: Dependencies
    @ObservationIgnored private var tokenSources: [String: CalendarTokenSource] = [:]
    /// Where an invitation's event is, nil for "on no calendar". Memory
    /// only, bounded, short-lived.
    @ObservationIgnored private var located: [LocateKey: (event: CalendarInviteEventRecord?, at: Date)] = [:]
    /// No Calendar request for the account before this time (rate limit).
    @ObservationIgnored private var pausedUntil: [String: Date] = [:]
    /// Bumped by disconnect and removal: work started before must not write
    /// its results back.
    @ObservationIgnored private var generation: [String: Int] = [:]
    private let now: @MainActor () -> Date

    /// One event: a UID, and the occurrence (`RECURRENCE-ID`) when the
    /// invitation is for one. Not the message: one message can carry several
    /// invitations, and several messages one event.
    struct LocateKey: Hashable {
        var accountId: String
        var uid: String
        var occurrence: String?
    }

    static let locateCacheLifetime: TimeInterval = 10 * 60
    static let locateCacheLimit = 200
    /// When Google says to slow down without saying for how long.
    static let defaultPause: TimeInterval = 60
    /// Longer invitations are not checked for conflicts: the window would
    /// read weeks of events.
    static let maxCheckedSpan: TimeInterval = 31 * 24 * 3600
    /// What the invitation sends to `events.import`, cut short: it is
    /// written by the sender.
    static let importTextLimit = 200

    init(dependencies: Dependencies, now: @escaping @MainActor () -> Date = { Date() }) {
        deps = dependencies
        self.now = now
    }

    // MARK: Account

    func status(for accountId: String) -> CalendarAccountStatus {
        guard deps.enabled else { return .off }
        guard let grant = grants[accountId], !grant.isEmpty else { return .notConnected }
        return needingConsent.contains(accountId) ? .needsConsent : .connected(grant)
    }

    /// Reads the account's grant and chosen calendars. Nothing with the
    /// switch off.
    func load(accountId: String) async {
        guard deps.enabled else { return }
        let started = generation[accountId, default: 0]
        let db = deps.database()
        let row = try? await db.read { db in
            (try CalendarStore.grant(db, accountId: accountId),
             try CalendarStore.chosenCalendars(db, accountId: accountId))
        }
        guard generation[accountId, default: 0] == started else { return }
        grants[accountId] = row?.0
        chosen[accountId] = row?.1 ?? []
        loaded.insert(accountId)
    }

    /// The separate Calendar consent in the browser, on an explicit user
    /// action. The first grant chooses the primary calendar; a reconnect
    /// keeps the user's choice. False when a consent for the account is
    /// already open (nothing was done).
    @discardableResult
    func connect(accountId: String) async throws -> Bool {
        guard deps.enabled else { throw CalendarError.switchedOff }
        guard !connecting.contains(accountId) else { return false }
        connecting.insert(accountId)
        defer { connecting.remove(accountId) }
        let grant = try await CalendarAuthorization.request(
            accountId: accountId, enabled: deps.enabled, steps: deps.steps)
        let tokens = tokenSource(accountId)
        await tokens.invalidate()
        // The calendar list names the primary calendar; without it (scope
        // unticked, offline) "primary" stands for it.
        let calendars: [GCalendarListEntry] = grant.canListCalendars
            ? ((try? await client(accountId, grant).calendars()) ?? [])
            : []
        let scopes = grant.scopes.sorted().joined(separator: " ")
        try await deps.database().write { db in
            try CalendarStore.saveGrant(db, accountId: accountId, scopes: scopes, at: Date(),
                                        calendars: calendars)
            if !calendars.isEmpty {
                try CalendarStore.reconcileChosenCalendars(db, accountId: accountId, with: calendars)
            }
        }
        needingConsent.remove(accountId)
        pausedUntil[accountId] = nil
        forgetLocated(accountId)
        await load(accountId: accountId)
        return true
    }

    /// Forgets the token first (so nothing can use it once the rows are
    /// gone), then the grant and the chosen calendars, then the memory.
    func disconnect(accountId: String) async throws {
        guard deps.enabled else { throw CalendarError.switchedOff }
        let status = deps.deleteRefreshToken(accountId)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CalendarError.keychainUnavailable(status)
        }
        try await deps.database().write { db in
            try CalendarStore.forget(db, accountId: accountId)
        }
        await forget(accountId: accountId)
    }

    /// The account is gone (removed) or disconnected: everything the
    /// integration holds for it in memory goes, the cached access token
    /// included. The database rows and the Keychain token are the account
    /// removal's (`AccountLifecycle`, `removeOutsideDatabase`).
    func forget(accountId: String) async {
        generation[accountId, default: 0] += 1
        await tokenSources[accountId]?.invalidate()
        tokenSources[accountId] = nil
        grants[accountId] = nil
        chosen[accountId] = nil
        loaded.remove(accountId)
        needingConsent.remove(accountId)
        pausedUntil[accountId] = nil
        forgetLocated(accountId)
    }

    // MARK: Chosen calendars

    /// Every calendar the account can see, for the choice in Settings.
    func calendarList(accountId: String) async throws -> [GCalendarListEntry] {
        let grant = try usableGrant(accountId)
        guard grant.canListCalendars else { throw CalendarError.notGranted(.calendarList) }
        try checkNotPaused(accountId)
        do {
            return try await client(accountId, grant).calendars()
        } catch {
            noteFailure(error, accountId: accountId)
            throw error
        }
    }

    func choose(_ entries: [GCalendarListEntry], accountId: String) async throws {
        guard deps.enabled else { throw CalendarError.switchedOff }
        try await deps.database().write { db in
            try CalendarStore.setChosenCalendars(db, accountId: accountId, entries)
        }
        forgetLocated(accountId)
        await load(accountId: accountId)
    }

    // MARK: Invitation

    /// Where the invitation's event is and whether the user is free, from
    /// the chosen calendars. Never throws: every failure is a state the card
    /// shows. `occurrence` is the invitation's `RECURRENCE-ID`, if any.
    func check(_ facts: CalendarInviteFacts, occurrence: String? = nil, messageId: String,
               accountId: String) async -> CalendarInviteCheck {
        guard deps.enabled else { return .off }
        if !loaded.contains(accountId) { await load(accountId: accountId) }
        guard case .connected(let grant) = status(for: accountId) else {
            return .unusable(status(for: accountId))
        }
        if isPaused(accountId) { return .failed(Self.pausedMessage) }
        let started = generation[accountId, default: 0]
        let service = CalendarInviteService(client: client(accountId, grant), grant: grant)
        let calendars = chosen[accountId] ?? []
        let key = LocateKey(accountId: accountId, uid: facts.uid, occurrence: occurrence)
        do {
            let event: CalendarInviteEventRecord?
            if let cached = cachedLocation(key) {
                event = cached.event
            } else if grant.canReadEvents {
                event = try await service.locate(facts, chosen: calendars, messageId: messageId,
                                                 accountId: accountId)
                guard generation[accountId, default: 0] == started else {
                    return .unusable(status(for: accountId))
                }
                remember(event, for: key)
            } else {
                event = nil
            }
            var findings = CalendarInviteFindings(event: event, grant: grant)
            if let span = facts.span, span.end.timeIntervalSince(span.start) > Self.maxCheckedSpan {
                findings.availabilitySkipped = true
            } else {
                findings.availability = try await service.availability(for: facts, chosen: calendars)
            }
            guard generation[accountId, default: 0] == started else {
                return .unusable(status(for: accountId))
            }
            return .ready(findings)
        } catch {
            guard generation[accountId, default: 0] == started else {
                return .unusable(status(for: accountId))
            }
            return noteFailure(error, accountId: accountId)
        }
    }

    /// Accept / Decline / Maybe. The e-mail reply goes first (`sendEmail`,
    /// #51's path): a slow or failing Calendar never delays or stops it.
    /// Only once it went is the answer also written on the calendar that
    /// holds this very event (`CalendarRSVPRoute`); a failed write is only
    /// reported.
    func answer(_ response: CalendarResponse, facts: CalendarInviteFacts,
                occurrence: String? = nil, findings: CalendarInviteFindings?,
                accountId: String,
                sendEmail: () async -> Bool) async -> CalendarAnswerResult {
        guard facts.isAnswerable else { return .notSent }
        guard await sendEmail() else { return .notSent }
        var result = CalendarAnswerResult(emailSent: true, calendarWritten: false,
                                          calendarFailure: nil, eventGone: false)
        guard deps.enabled, let findings, case .connected(let grant) = status(for: accountId),
              case .calendarAndEmail = findings.route(for: facts) else { return result }
        if isPaused(accountId) {
            result.calendarFailure = Self.pausedMessage
            return result
        }
        let service = CalendarInviteService(client: client(accountId, grant), grant: grant)
        let outcome = await service.respond(response, facts: facts, event: findings.event)
        result.calendarWritten = outcome.calendarWritten
        result.eventGone = outcome.eventGone
        if outcome.eventGone {
            located[LocateKey(accountId: accountId, uid: facts.uid, occurrence: occurrence)] = nil
        } else if let error = outcome.calendarError {
            noteFailure(error, accountId: accountId)
            result.calendarFailure = Self.message(for: error)
        }
        return result
    }

    /// "Add to calendar" on the primary calendar, with `attendeeEmail` (the
    /// address the answer goes from) as the guest. Looks the UID up again
    /// first, without the cache: an event already on a calendar is not
    /// imported twice. The sender's title and place are cut short. Returns
    /// the findings with the event, so the card's route follows it.
    func addToCalendar(_ facts: CalendarInviteFacts, occurrence: String? = nil,
                       findings: CalendarInviteFindings, organizerIsSender: Bool,
                       attendeeEmail: String, messageId: String,
                       accountId: String) async throws -> CalendarInviteFindings {
        guard deps.enabled else { throw CalendarError.switchedOff }
        let grant = try usableGrant(accountId)
        guard findings.canAddToCalendar(facts, organizerIsSender: organizerIsSender) else {
            throw CalendarError.notGranted(.writeEvents)
        }
        try checkNotPaused(accountId)
        let started = generation[accountId, default: 0]
        let key = LocateKey(accountId: accountId, uid: facts.uid, occurrence: occurrence)
        let service = CalendarInviteService(client: client(accountId, grant), grant: grant)
        do {
            var updated = findings
            if let existing = try await service.locate(facts, chosen: chosen[accountId] ?? [],
                                                       messageId: messageId, accountId: accountId) {
                updated.event = existing
            } else {
                updated.event = try await service.addToCalendar(
                    Self.importable(facts), attendeeEmail: attendeeEmail,
                    messageId: messageId, accountId: accountId)
            }
            if generation[accountId, default: 0] == started { remember(updated.event, for: key) }
            return updated
        } catch {
            noteFailure(error, accountId: accountId)
            throw error
        }
    }

    /// The invitation as it may be imported: the sender's title and place,
    /// display-safe and short.
    static func importable(_ facts: CalendarInviteFacts) -> CalendarInviteFacts {
        var safe = facts
        safe.summary = CalendarInvite.displaySafe(facts.summary, limit: importTextLimit)
        safe.location = CalendarInvite.displaySafe(facts.location, limit: importTextLimit)
        return safe
    }

    // MARK: Plumbing

    private func usableGrant(_ accountId: String) throws -> CalendarGrant {
        switch status(for: accountId) {
        case .off: throw CalendarError.switchedOff
        case .connected(let grant): return grant
        case .notConnected, .needsConsent: throw CalendarError.notGranted(nil)
        }
    }

    private func isPaused(_ accountId: String) -> Bool {
        guard let until = pausedUntil[accountId] else { return false }
        return until > now()
    }

    private func checkNotPaused(_ accountId: String) throws {
        if isPaused(accountId) { throw CalendarError.rateLimited(retryAfter: nil) }
    }

    static var pausedMessage: String {
        CalendarError.rateLimited(retryAfter: nil).errorDescription ?? "Google Calendar is busy."
    }

    private func tokenSource(_ accountId: String) -> CalendarTokenSource {
        if let source = tokenSources[accountId] { return source }
        let source = CalendarTokenSource(accountId: accountId, enabled: deps.enabled,
                                         readRefreshToken: deps.readRefreshToken,
                                         refresh: deps.refresh)
        tokenSources[accountId] = source
        return source
    }

    private func client(_ accountId: String, _ grant: CalendarGrant) -> CalendarClient {
        CalendarClient(grant: grant, tokens: tokenSource(accountId),
                       transport: .gated(enabled: deps.enabled, deps.transport))
    }

    private func cachedLocation(_ key: LocateKey) -> (event: CalendarInviteEventRecord?, at: Date)? {
        guard let cached = located[key],
              now().timeIntervalSince(cached.at) < Self.locateCacheLifetime else { return nil }
        return cached
    }

    private func remember(_ event: CalendarInviteEventRecord?, for key: LocateKey) {
        let time = now()
        located = located.filter { time.timeIntervalSince($0.value.at) < Self.locateCacheLifetime }
        while located.count >= Self.locateCacheLimit,
              let oldest = located.min(by: { $0.value.at < $1.value.at })?.key {
            located[oldest] = nil
        }
        located[key] = (event, time)
    }

    private func forgetLocated(_ accountId: String) {
        located = located.filter { $0.key.accountId != accountId }
    }

    /// For tests: how many invitation locations are held in memory.
    var locatedCount: Int { located.count }

    /// The card state for a failure. Only Google refusing the grant marks
    /// the account as needing consent; a scope the user did not grant is
    /// an error of that call. A rate limit pauses the account's requests.
    @discardableResult
    private func noteFailure(_ error: Error, accountId: String) -> CalendarInviteCheck {
        if case .rateLimited(let retryAfter)? = error as? CalendarError {
            pausedUntil[accountId] = now().addingTimeInterval(retryAfter ?? Self.defaultPause)
        }
        return Self.check(for: error, onRefusedGrant: { needingConsent.insert(accountId) })
    }

    /// Pure mapping from an error to what the card shows.
    static func check(for error: Error, onRefusedGrant: () -> Void = {}) -> CalendarInviteCheck {
        switch error as? CalendarError {
        case .switchedOff?:
            return .off
        case .notGranted(.none)?:
            onRefusedGrant()
            return .needsConsent
        case .notGranted(.some(_))?:
            return .failed(missingScopeMessage)
        case let calendarError?:
            return .failed(message(for: calendarError))
        case nil:
            return TransientNetworkError.isTransient(error)
                ? .offline : .failed("Google Calendar could not be checked.")
        }
    }

    static let missingScopeMessage =
        "This needs a Google Calendar permission that was not granted. Reconnect to grant it."

    /// A Calendar error as one sentence without any response body.
    static func message(for error: Error) -> String {
        if TransientNetworkError.isTransient(error) {
            return "You're offline — Google Calendar can't be reached."
        }
        switch error as? CalendarError {
        case .notGranted(.some(_))?: return missingScopeMessage
        case let calendarError?: return calendarError.errorDescription ?? "Google Calendar failed."
        case nil: return "Google Calendar failed."
        }
    }
}
