import Foundation

// MARK: - Errors

enum CalendarError: LocalizedError, Equatable {
    /// The build has no Calendar integration (`CalendarFeatures`).
    case switchedOff
    /// The account has no Calendar grant, or not the one this call needs
    /// (the user unticked it, withdrew it, or Google revoked it).
    case notGranted(CalendarCapability?)
    /// The Calendar consent was given for another Google account.
    case wrongAccount
    /// Quota or rate limit (429, or 403 with a rate-limit reason).
    case rateLimited(retryAfter: TimeInterval?)
    /// The user is not among the event's attendees, so has no answer to set.
    case notAnAttendee
    case keychainUnavailable(OSStatus)
    /// Any other HTTP failure: the status and Google's reason token, never
    /// the body (it can repeat event titles and addresses).
    case http(Int, reason: String?)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .switchedOff: return CalendarFeatures.disabledMessage
        case .notGranted: return "Google Calendar is not connected for this account."
        case .wrongAccount:
            return "Calendar access was given for a different Google account. Try again and pick the same account."
        case .rateLimited: return "Google Calendar asked MishMail to slow down. Try again shortly."
        case .notAnAttendee: return "You are not a guest of this event."
        case .keychainUnavailable(let status):
            return "MishMail couldn't read the saved Calendar sign-in (Keychain error \(status))."
        case .http(let code, let reason):
            return "Google Calendar error \(code)" + (reason.map { " (\($0))" } ?? "")
        case .badResponse: return "Google Calendar sent a response MishMail could not read."
        }
    }

    /// Maps a non-2xx response. Pure, for the hostless tests.
    static func classify(status: Int, body: Data, retryAfterHeader: String?) -> CalendarError {
        let reason = Self.reason(in: body)
        switch status {
        case 429:
            return .rateLimited(retryAfter: retryAfter(retryAfterHeader))
        case 403:
            if let reason, reason.lowercased().contains("ratelimitexceeded")
                || reason == "quotaExceeded" {
                return .rateLimited(retryAfter: retryAfter(retryAfterHeader))
            }
            if let reason, ["insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
                            "PERMISSION_DENIED"].contains(reason) {
                return .notGranted(nil)
            }
            return .http(403, reason: reason)
        default:
            return .http(status, reason: reason)
        }
    }

    /// `Retry-After` in seconds, or as an HTTP date (RFC 9110), as a delay
    /// from `now`. Nil when absent or unreadable.
    static func retryAfter(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw), seconds >= 0 { return seconds }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = f.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// Google's reason token (`errors[].reason`, `details[].reason` or
    /// `status`), only when it is a safe token (`DiagnosticLog.token`).
    static func reason(in body: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let err = object["error"] as? [String: Any] else { return nil }
        let items = (err["errors"] as? [[String: Any]] ?? []) + (err["details"] as? [[String: Any]] ?? [])
        return items.lazy.compactMap { ($0["reason"] as? String).flatMap(DiagnosticLog.token) }.first
            ?? (err["status"] as? String).flatMap(DiagnosticLog.token)
    }
}

// MARK: - Transport

/// The one network path to the Calendar API.
struct CalendarTransport: Sendable {
    var data: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// With `enabled` false every call throws `CalendarError.switchedOff`
    /// before `base` sees the request.
    static func gated(enabled: Bool, _ base: CalendarTransport) -> CalendarTransport {
        CalendarTransport { request in
            guard enabled else { throw CalendarError.switchedOff }
            return try await base.data(request)
        }
    }

    /// Google's shared ephemeral session: no disk cache, no cookies.
    /// Private: the only way to it is `live`, behind the switch.
    private static let session = CalendarTransport { try await GoogleHTTP.session.data(for: $0) }

    /// What the app uses: the session behind the build's switch.
    static let live = gated(enabled: CalendarFeatures.isEnabled, session)
}

// MARK: - Access tokens

/// The Calendar access token of one account, from its own refresh token
/// (`CalendarAuthorization.keychainKey`). Separate from `GmailClient`'s:
/// the two grants are independent.
actor CalendarTokenSource {
    typealias ReadRefreshToken = @Sendable (String) -> KeychainReadResult
    typealias Refresh = @Sendable (String) async throws -> (token: String, expiresIn: Int)

    private let accountId: String
    private let enabled: Bool
    private let readRefreshToken: ReadRefreshToken
    private let refresh: Refresh
    private var cache = AccessTokenCache()
    private let now: @Sendable () -> Date

    init(accountId: String,
         enabled: Bool = CalendarFeatures.isEnabled,
         readRefreshToken: @escaping ReadRefreshToken = { Keychain.read($0) },
         refresh: @escaping Refresh = { try await OAuthService.refreshAccessToken(refreshToken: $0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.accountId = accountId
        self.enabled = enabled
        self.readRefreshToken = readRefreshToken
        self.refresh = refresh
        self.now = now
    }

    /// Refuses with the switch off before the Keychain is read.
    func token() async throws -> String {
        guard enabled else { throw CalendarError.switchedOff }
        if let token = cache.token(now: now()) { return token }
        let generation = cache.generation
        let stored: String
        switch readRefreshToken(CalendarAuthorization.keychainKey(accountId: accountId)) {
        case .value(let value): stored = value
        case .notFound: throw CalendarError.notGranted(nil)
        case .unavailable(let status): throw CalendarError.keychainUnavailable(status)
        }
        let result: (token: String, expiresIn: Int)
        do {
            result = try await refresh(stored)
        } catch OAuthError.invalidGrant {
            // Revoked in the Google account, or expired: Calendar is no
            // longer connected; mail is not affected.
            throw CalendarError.notGranted(nil)
        }
        if cache.store(result.token, expiresIn: result.expiresIn, now: now(),
                       generation: generation) {
            return result.token
        }
        return try await token()
    }

    /// The server rejected the token (401).
    func expire() { cache.expire() }

    /// The grant changed (connected again, withdrawn, account removed).
    func invalidate() { cache.invalidate() }
}

// MARK: - Wire models (subset of Calendar API v3)

struct GCalendarListEntry: Decodable, Equatable, Sendable {
    let id: String
    let summary: String?
    let timeZone: String?
    let primary: Bool?
    /// "freeBusyReader" | "reader" | "writer" | "owner".
    let accessRole: String?
}

struct GCalendarList: Decodable, Sendable {
    let items: [GCalendarListEntry]?
    let nextPageToken: String?
}

struct GEventDateTime: Decodable, Equatable, Sendable {
    /// All-day events: `yyyy-MM-dd`, end exclusive.
    let date: String?
    /// Timed events: RFC 3339 with an offset.
    let dateTime: String?
    let timeZone: String?

    init(date: String? = nil, dateTime: String? = nil, timeZone: String? = nil) {
        self.date = date
        self.dateTime = dateTime
        self.timeZone = timeZone
    }
}

struct GEventAttendee: Decodable, Equatable, Sendable {
    let email: String?
    /// True on the attendee entry of the authenticated user (`self`).
    let isSelf: Bool?
    /// "needsAction" | "declined" | "tentative" | "accepted".
    let responseStatus: String?

    init(email: String?, isSelf: Bool? = nil, responseStatus: String?) {
        self.email = email
        self.isSelf = isSelf
        self.responseStatus = responseStatus
    }

    private enum CodingKeys: String, CodingKey {
        case email, responseStatus
        case isSelf = "self"
    }
}

struct GEventOrganizer: Decodable, Equatable, Sendable {
    let email: String?
}

struct GCalendarEvent: Decodable, Equatable, Sendable {
    let id: String
    /// "confirmed" | "tentative" | "cancelled".
    let status: String?
    let summary: String?
    let iCalUID: String?
    let recurringEventId: String?
    let start: GEventDateTime?
    let end: GEventDateTime?
    /// "opaque" (default, busy) | "transparent" (free).
    let transparency: String?
    let attendees: [GEventAttendee]?
    /// As Google has it, not as the invitation's ICS claims.
    let organizer: GEventOrganizer?

    init(id: String, status: String? = "confirmed", summary: String? = nil,
         iCalUID: String? = nil, recurringEventId: String? = nil,
         start: GEventDateTime?, end: GEventDateTime?, transparency: String? = nil,
         attendees: [GEventAttendee]? = nil, organizer: GEventOrganizer? = nil) {
        self.id = id
        self.status = status
        self.summary = summary
        self.iCalUID = iCalUID
        self.recurringEventId = recurringEventId
        self.start = start
        self.end = end
        self.transparency = transparency
        self.attendees = attendees
        self.organizer = organizer
    }

    /// The authenticated user's own answer, when they are a guest.
    var selfResponse: String? {
        attendees?.first { $0.isSelf == true }?.responseStatus
    }
}

struct GEventList: Decodable, Sendable {
    let items: [GCalendarEvent]?
    let nextPageToken: String?
    /// The calendar's time zone: what an all-day date means.
    let timeZone: String?
}

struct GFreeBusyResponse: Decodable, Sendable {
    struct Period: Decodable, Sendable { let start: String; let end: String }
    struct Calendar: Decodable, Sendable {
        struct Problem: Decodable, Sendable { let reason: String? }
        let busy: [Period]?
        let errors: [Problem]?
    }
    let calendars: [String: Calendar]?
}

/// The events of one calendar in a window, all pages read.
struct CalendarEventPage: Sendable {
    var events: [GCalendarEvent]
    var calendarTimeZone: String?
}

/// A calendar's busy periods from freebusy.query.
struct CalendarFreeBusy: Equatable, Sendable {
    var calendarId: String
    var busy: [DateInterval]
    /// Google could not answer for this calendar (e.g. "notFound").
    var failed: Bool
}

/// The user's answer to an invitation, as the Calendar API spells it.
enum CalendarResponse: String, Sendable {
    case accepted, declined, tentative
}

// MARK: - Client

/// Thin client over the Calendar API v3 for one account. Every call checks
/// the grant first and fails with `notGranted` before any request when the
/// needed scope is missing.
actor CalendarClient {
    static let base = "https://www.googleapis.com/calendar/v3"
    /// Google's page size limit for events.list is 2500; 250 keeps pages
    /// small and is also calendarList's maximum.
    static let pageSize = 250
    /// A pathological server cannot keep a listing paging forever.
    static let maxPages = 200
    /// freebusy.query takes at most 50 calendars per request.
    static let freeBusyBatch = 50
    /// Longest invitation UID sent to Google, as `CalendarInvite` caps the
    /// lines it echoes. A longer one is not looked up.
    static let maxUIDBytes = CalendarInvite.Limits.maxEchoBytes

    private let grant: CalendarGrant
    private let transport: CalendarTransport
    private let tokens: CalendarTokenSource

    init(grant: CalendarGrant, tokens: CalendarTokenSource,
         transport: CalendarTransport = .live) {
        self.grant = grant
        self.tokens = tokens
        self.transport = transport
    }

    // MARK: Calendars

    func calendars() async throws -> [GCalendarListEntry] {
        try require(.calendarList)
        var all: [GCalendarListEntry] = []
        var pageToken: String?
        for _ in 0..<Self.maxPages {
            var query = ["maxResults": String(Self.pageSize)]
            query["pageToken"] = pageToken
            let page: GCalendarList = try await get("/users/me/calendarList", query: query)
            all += page.items ?? []
            guard let next = page.nextPageToken, !next.isEmpty else { return all }
            pageToken = next
        }
        throw CalendarError.badResponse
    }

    // MARK: Events

    /// Events overlapping `interval`, recurring ones expanded into
    /// instances by Google (`singleEvents`).
    func events(calendarId: String, in interval: DateInterval) async throws -> CalendarEventPage {
        try require(.events)
        return try await pagedEvents(calendarId: calendarId, query: [
            "singleEvents": "true",
            "timeMin": Self.rfc3339(interval.start),
            "timeMax": Self.rfc3339(interval.end),
        ])
    }

    private func pagedEvents(calendarId: String, query base: [String: String]) async throws -> CalendarEventPage {
        var result = CalendarEventPage(events: [])
        var pageToken: String?
        for _ in 0..<Self.maxPages {
            var query = base
            query["maxResults"] = String(Self.pageSize)
            query["pageToken"] = pageToken
            let page: GEventList = try await get(
                "/calendars/\(Self.pathSegment(calendarId))/events", query: query)
            result.events += page.items ?? []
            result.calendarTimeZone = result.calendarTimeZone ?? page.timeZone
            guard let next = page.nextPageToken, !next.isEmpty else { return result }
            pageToken = next
        }
        throw CalendarError.badResponse
    }

    /// The events of one calendar with this iCalendar UID: the invitation's
    /// own event when Google put it on the calendar. Cancelled ones are
    /// left out. An empty or over-long UID is not sent.
    func events(calendarId: String, iCalUID: String) async throws -> [GCalendarEvent] {
        try require(.events)
        guard !iCalUID.isEmpty, iCalUID.utf8.count <= Self.maxUIDBytes else { return [] }
        let result = try await pagedEvents(calendarId: calendarId, query: ["iCalUID": iCalUID])
        return result.events.filter { $0.status != "cancelled" }
    }

    /// "Add to calendar" for an invitation Google did not put on the
    /// calendar: `events.import` keeps the invitation's UID, so the organizer's
    /// later updates match it, and lists the user as a guest so the answer
    /// can be written on it. The body is `CalendarInvitePlan.importBody`.
    func importEvent(calendarId: String, facts: CalendarInviteFacts, attendeeEmail: String,
                     zone: TimeZone) async throws -> GCalendarEvent {
        try require(.writeEvents)
        guard let body = CalendarInvitePlan.importBody(facts, attendeeEmail: attendeeEmail, zone: zone) else {
            throw CalendarError.badResponse
        }
        let data = try await send("POST", "/calendars/\(Self.pathSegment(calendarId))/events/import",
                                  jsonBody: body)
        return try Self.decode(GCalendarEvent.self, data)
    }

    // MARK: Free/busy

    /// Busy periods per calendar, in requests of at most `freeBusyBatch`
    /// calendars.
    func freeBusy(calendarIds: [String], in interval: DateInterval) async throws -> [CalendarFreeBusy] {
        try require(.availability)
        var all: [CalendarFreeBusy] = []
        var start = 0
        while start < calendarIds.count {
            let batch = Array(calendarIds[start..<min(start + Self.freeBusyBatch, calendarIds.count)])
            all += try await queryFreeBusy(batch, in: interval)
            start += Self.freeBusyBatch
        }
        return all
    }

    private func queryFreeBusy(_ calendarIds: [String], in interval: DateInterval) async throws -> [CalendarFreeBusy] {
        let body: [String: Any] = [
            "timeMin": Self.rfc3339(interval.start),
            "timeMax": Self.rfc3339(interval.end),
            "items": calendarIds.map { ["id": $0] },
        ]
        let data = try await send("POST", "/freeBusy", jsonBody: body)
        let response = try Self.decode(GFreeBusyResponse.self, data)
        return calendarIds.map { id in
            let entry = response.calendars?[id]
            let busy = (entry?.busy ?? []).compactMap { period -> DateInterval? in
                guard let s = Self.parseDateTime(period.start),
                      let e = Self.parseDateTime(period.end), e >= s else { return nil }
                return DateInterval(start: s, end: e)
            }
            return CalendarFreeBusy(calendarId: id, busy: busy,
                                    failed: entry == nil || !(entry?.errors ?? []).isEmpty)
        }
    }

    // MARK: Answering an invitation

    /// Sets the user's own answer on an event in their calendar, asking
    /// Google to e-mail nobody (`sendUpdates=none`): the iTIP e-mail is the
    /// one answer the organizer gets. The attendees array is read and
    /// written back whole (Calendar replaces arrays on patch), changing only
    /// the user's `responseStatus`; every other field of every attendee is
    /// kept as Google sent it.
    func respond(calendarId: String, eventId: String, response: CalendarResponse) async throws {
        try require(.writeEvents)
        let path = "/calendars/\(Self.pathSegment(calendarId))/events/\(Self.pathSegment(eventId))"
        let current = try await send("GET", path, query: ["fields": "attendees"])
        let attendees = try Self.attendees(settingSelfResponse: response, in: current)
        _ = try await send("PATCH", path, query: ["sendUpdates": "none"],
                           jsonBody: ["attendees": attendees])
    }

    /// Pure: the attendees of `eventJSON` with the user's own entry set to
    /// `response`. Throws `notAnAttendee` when no entry is the user's.
    static func attendees(settingSelfResponse response: CalendarResponse,
                          in eventJSON: Data) throws -> [[String: Any]] {
        guard let object = (try? JSONSerialization.jsonObject(with: eventJSON)) as? [String: Any] else {
            throw CalendarError.badResponse
        }
        var attendees = object["attendees"] as? [[String: Any]] ?? []
        guard let index = attendees.firstIndex(where: { ($0["self"] as? Bool) == true }) else {
            throw CalendarError.notAnAttendee
        }
        attendees[index]["responseStatus"] = response.rawValue
        return attendees
    }

    // MARK: Requests

    private func require(_ capability: CalendarCapability) throws {
        guard grant.allows(capability) else { throw CalendarError.notGranted(capability) }
    }

    private func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        let data = try await send("GET", path, query: query)
        return try Self.decode(T.self, data)
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:],
                      jsonBody: [String: Any]? = nil) async throws -> Data {
        var refreshedAfter401 = false
        while true {
            var request = URLRequest(url: try Self.url(path: path, query: query))
            request.httpMethod = method
            request.setValue("Bearer \(try await tokens.token())", forHTTPHeaderField: "Authorization")
            if let jsonBody {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
            }
            let (data, response) = try await transport.data(request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (200..<300).contains(status) { return data }
            if status == 401, !refreshedAfter401 {
                await tokens.expire()
                refreshedAfter401 = true
                continue
            }
            if status == 401 { throw CalendarError.notGranted(nil) }
            throw CalendarError.classify(status: status, body: data,
                                         retryAfterHeader: http?.value(forHTTPHeaderField: "Retry-After"))
        }
    }

    // MARK: Encoding

    /// Calendar ids are addresses or `…#holiday@group.v.calendar.google.com`:
    /// `@` may stay, `#`, `/`, `?` and `%` must not.
    static func pathSegment(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~@")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func url(path: String, query: [String: String]) throws -> URL {
        guard var comps = URLComponents(string: base) else { throw CalendarError.badResponse }
        comps.percentEncodedPath += path
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // `+` is a space for Google's form decoding; RFC 3339 offsets
            // and page tokens can contain one.
            comps.percentEncodedQuery = comps.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = comps.url else { throw CalendarError.badResponse }
        return url
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CalendarError.badResponse
        }
    }

    static func rfc3339(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// RFC 3339 with or without fractional seconds.
    static func parseDateTime(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
