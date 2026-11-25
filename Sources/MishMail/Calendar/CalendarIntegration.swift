import Foundation
import GRDB
import Observation

/// One account's Calendar connection, as Settings and the invitation card
/// show it.
enum CalendarAccountStatus: Equatable, Sendable {
    /// The build has no Calendar integration: nothing is shown.
    case off
    case notConnected
    case connected(CalendarGrant)
    /// Connected once, but Google no longer accepts the grant (revoked,
    /// expired, or a scope the call needs was unticked). Reconnecting keeps
    /// the chosen calendars.
    case needsConsent

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
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
}

/// The answer to "am I free, and where is this event" for one invitation.
struct CalendarInviteFindings: Equatable, Sendable {
    /// Nil when the invitation has no usable time or no calendar is chosen.
    var availability: CalendarAvailabilityResult?
    /// The invitation's event in the user's Google Calendar; nil when it is
    /// on none of the calendars looked at.
    var event: CalendarInviteEventRecord?
    var grant: CalendarGrant

    /// Where Accept / Decline / Maybe goes (`CalendarRSVPRoute`).
    func route(for facts: CalendarInviteFacts) -> CalendarRSVPRoute {
        CalendarRSVPRoute.route(for: facts, event: event, canWrite: grant.canWriteEvents)
    }

    func canAddToCalendar(_ facts: CalendarInviteFacts) -> Bool {
        CalendarInvitePlan.canAddToCalendar(facts, event: event, canWrite: grant.canWriteEvents)
    }
}

/// The text under the RSVP buttons: where the answer goes, from whom.
/// Pure, so each route's wording is tested. The e-mail always goes
/// (`CalendarRSVPRoute`); the calendar only when it holds this very event.
enum CalendarAnswerNote {
    static func text(route: CalendarRSVPRoute, accountId: String, from: String,
                     organizer: String) -> String {
        switch route {
        case .calendarAndEmail:
            return "Answer saved in Google Calendar (\(accountId)), and reply from \(from) goes to \(organizer)"
        case .emailOnly, .notAnswerable:
            return "Reply from \(from) goes to \(organizer)"
        }
    }
}

/// The Calendar integration as the app's UI sees it: connect and disconnect
/// one account, choose its calendars, check an invitation, answer it, add it
/// to the calendar. The only door from outside the Calendar folder.
///
/// Stores nothing beyond `CalendarStore`'s rows (the grant and the chosen
/// calendars): an invitation's event and availability stay in memory, so
/// there is nothing more to delete with a message (DEC-019). Where each
/// invitation's event is (or that it is on no calendar) is kept in memory
/// for `locateCacheLifetime`, so reopening a message does not ask every
/// chosen calendar again; a rate limit pauses the account's checks for as
/// long as Google asks. Logs nothing.
/// With the switch off every method refuses before any request, Keychain
/// read or browser.
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
        var deleteRefreshToken: @Sendable (_ accountId: String) -> Void

        static let live = Dependencies(
            enabled: CalendarFeatures.isEnabled,
            database: { AppDatabase.shared.dbPool },
            steps: .live,
            transport: .live,
            readRefreshToken: { Keychain.read($0) },
            refresh: { try await OAuthService.refreshAccessToken(refreshToken: $0) },
            deleteRefreshToken: { Keychain.delete(CalendarAuthorization.keychainKey(accountId: $0)) })
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
    /// Where an invitation's event is, nil for "on no calendar", by account
    /// and message. Memory only, bounded, short-lived.
    @ObservationIgnored private var located: [LocateKey: (event: CalendarInviteEventRecord?, at: Date)] = [:]
    /// No Calendar request for the account before this time (rate limit).
    @ObservationIgnored private var pausedUntil: [String: Date] = [:]
    private let now: @MainActor () -> Date

    private struct LocateKey: Hashable {
        var accountId: String
        var messageId: String
    }

    static let locateCacheLifetime: TimeInterval = 10 * 60
    static let locateCacheLimit = 200
    /// When Google says to slow down without saying for how long.
    static let defaultPause: TimeInterval = 60

    var isEnabled: Bool { deps.enabled }

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
        let db = deps.database()
        let row = try? await db.read { db in
            (try CalendarStore.grant(db, accountId: accountId),
             try CalendarStore.chosenCalendars(db, accountId: accountId))
        }
        grants[accountId] = row?.0
        chosen[accountId] = row?.1 ?? []
        loaded.insert(accountId)
    }

    /// The separate Calendar consent in the browser, on an explicit user
    /// action. The first grant chooses the primary calendar; a reconnect
    /// keeps the user's choice.
    func connect(accountId: String) async throws {
        guard deps.enabled else { throw CalendarError.switchedOff }
        guard !connecting.contains(accountId) else { return }
        connecting.insert(accountId)
        defer { connecting.remove(accountId) }
        let grant = try await CalendarAuthorization.request(
            accountId: accountId, enabled: deps.enabled, steps: deps.steps)
        let tokens = tokenSource(accountId)
        await tokens.invalidate()
        // The calendar list names the primary calendar; without it (scope
        // unticked, offline) "primary" stands for it.
        var calendars: [GCalendarListEntry] = []
        if grant.canListCalendars {
            calendars = (try? await client(accountId, grant).calendars()) ?? []
        }
        let scopes = grant.scopes.sorted().joined(separator: " ")
        try await deps.database().write { db in
            try CalendarStore.saveGrant(db, accountId: accountId, scopes: scopes, at: Date(),
                                        calendars: calendars)
            if !calendars.isEmpty {
                try CalendarStore.reconcileChosenCalendars(db, accountId: accountId, with: calendars)
            }
        }
        needingConsent.remove(accountId)
        forgetLocated(accountId)
        await load(accountId: accountId)
    }

    /// Forgets the grant, the chosen calendars and the token.
    func disconnect(accountId: String) async throws {
        guard deps.enabled else { throw CalendarError.switchedOff }
        try await deps.database().write { db in
            try CalendarStore.forget(db, accountId: accountId)
        }
        deps.deleteRefreshToken(accountId)
        await tokenSources[accountId]?.invalidate()
        tokenSources[accountId] = nil
        needingConsent.remove(accountId)
        forgetLocated(accountId)
        pausedUntil[accountId] = nil
        grants[accountId] = nil
        chosen[accountId] = []
    }

    // MARK: Chosen calendars

    /// Every calendar the account can see, for the choice in Settings.
    func calendarList(accountId: String) async throws -> [GCalendarListEntry] {
        let grant = try usableGrant(accountId)
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
    /// shows.
    func check(_ facts: CalendarInviteFacts, messageId: String,
               accountId: String) async -> CalendarInviteCheck {
        guard deps.enabled else { return .off }
        if !loaded.contains(accountId) { await load(accountId: accountId) }
        switch status(for: accountId) {
        case .off: return .off
        case .notConnected: return .notConnected
        case .needsConsent: return .needsConsent
        case .connected(let grant):
            if let until = pausedUntil[accountId], until > now() {
                return .failed(CalendarError.rateLimited(retryAfter: nil).errorDescription ?? "")
            }
            let service = CalendarInviteService(client: client(accountId, grant), grant: grant)
            let calendars = chosen[accountId] ?? []
            let key = LocateKey(accountId: accountId, messageId: messageId)
            do {
                let event: CalendarInviteEventRecord?
                if let cached = located[key], now().timeIntervalSince(cached.at) < Self.locateCacheLifetime {
                    event = cached.event
                } else if grant.canReadEvents {
                    event = try await service.locate(facts, chosen: calendars, messageId: messageId,
                                                     accountId: accountId)
                    remember(event, for: key)
                } else {
                    event = nil
                }
                let availability = try await service.availability(for: facts, chosen: calendars)
                return .ready(CalendarInviteFindings(availability: availability, event: event,
                                                     grant: grant))
            } catch {
                return noteFailure(error, accountId: accountId)
            }
        }
    }

    /// Writes the answer on the calendar where the route says so. Never
    /// throws: the caller sends the e-mail reply whenever
    /// `route.sendsEmail`, whatever the calendar write did.
    func respond(_ response: CalendarResponse, facts: CalendarInviteFacts,
                 findings: CalendarInviteFindings?, messageId: String,
                 accountId: String) async -> CalendarRSVPOutcome {
        guard deps.enabled, let findings, case .connected(let grant) = status(for: accountId) else {
            return CalendarRSVPOutcome(route: facts.isAnswerable ? .emailOnly : .notAnswerable,
                                       calendarWritten: false, eventGone: false, calendarError: nil)
        }
        let service = CalendarInviteService(client: client(accountId, grant), grant: grant)
        let outcome = await service.respond(response, facts: facts, event: findings.event)
        if outcome.eventGone {
            located[LocateKey(accountId: accountId, messageId: messageId)] = nil
        }
        if let error = outcome.calendarError { noteFailure(error, accountId: accountId) }
        return outcome
    }

    /// "Add to calendar" on the primary calendar, with `attendeeEmail` (the
    /// address the answer goes from) as the guest. Returns the findings
    /// with the new event, so the card's route follows it.
    func addToCalendar(_ facts: CalendarInviteFacts, findings: CalendarInviteFindings,
                       attendeeEmail: String, messageId: String,
                       accountId: String) async throws -> CalendarInviteFindings {
        guard deps.enabled else { throw CalendarError.switchedOff }
        let grant = try usableGrant(accountId)
        guard findings.canAddToCalendar(facts) else { throw CalendarError.notGranted(.writeEvents) }
        let service = CalendarInviteService(client: client(accountId, grant), grant: grant)
        do {
            var updated = findings
            let event = try await service.addToCalendar(facts, attendeeEmail: attendeeEmail,
                                                        messageId: messageId, accountId: accountId)
            updated.event = event
            remember(event, for: LocateKey(accountId: accountId, messageId: messageId))
            return updated
        } catch {
            noteFailure(error, accountId: accountId)
            throw error
        }
    }

    // MARK: Plumbing

    private func usableGrant(_ accountId: String) throws -> CalendarGrant {
        switch status(for: accountId) {
        case .off: throw CalendarError.switchedOff
        case .connected(let grant): return grant
        case .notConnected, .needsConsent: throw CalendarError.notGranted(nil)
        }
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

    private func remember(_ event: CalendarInviteEventRecord?, for key: LocateKey) {
        let time = now()
        located = located.filter { time.timeIntervalSince($0.value.at) < Self.locateCacheLifetime }
        if located.count >= Self.locateCacheLimit,
           let oldest = located.min(by: { $0.value.at < $1.value.at })?.key {
            located[oldest] = nil
        }
        located[key] = (event, time)
    }

    private func forgetLocated(_ accountId: String) {
        located = located.filter { $0.key.accountId != accountId }
    }

    /// The card state for a failure; a refused grant is remembered so
    /// Settings and the other cards offer to reconnect, and a rate limit
    /// pauses the account's checks.
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
        case .notGranted?:
            onRefusedGrant()
            return .needsConsent
        case let calendarError?:
            return .failed(calendarError.errorDescription ?? "Google Calendar could not be checked.")
        case nil:
            return TransientNetworkError.isTransient(error)
                ? .offline : .failed("Google Calendar could not be checked.")
        }
    }
}
