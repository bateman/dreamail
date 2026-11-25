import Foundation

/// Google Calendar OAuth scopes the integration may ask for. Which ones the
/// first release asks for is the owner's decision (step 4A design); the
/// request takes the set as a parameter and `recommended` is only a default.
enum CalendarScope {
    static let prefix = "https://www.googleapis.com/auth/"
    /// See free/busy on calendars the user can access (freebusy.query,
    /// events.list without titles).
    static let eventsFreeBusy = prefix + "calendar.events.freebusy"
    /// View and edit events on all calendars (events.list, events.patch).
    static let events = prefix + "calendar.events"
    /// View events on all calendars.
    static let eventsReadOnly = prefix + "calendar.events.readonly"
    /// See the list of calendars the user subscribes to.
    static let calendarListReadOnly = prefix + "calendar.calendarlist.readonly"
    /// See and download any calendar (also accepted by freebusy.query).
    static let readOnly = prefix + "calendar.readonly"
    /// Full access, never requested; recognised only so a wider grant is
    /// not mistaken for none.
    static let full = prefix + "calendar"
    /// View availability; also accepted by freebusy.query.
    static let freeBusy = prefix + "calendar.freebusy"

    /// Option B of the design: availability, answering on the calendar and
    /// "add to calendar". `calendar.events` (all calendars, shared ones
    /// included) is the owner's choice (DEC-048), over the narrower
    /// `calendar.events.owned`.
    static let recommended = [eventsFreeBusy, events, calendarListReadOnly]

    /// Asked for with the Calendar scopes so the grant can be checked
    /// against the account it is for (the browser may be signed in to
    /// another Google account). Non-sensitive; already part of the Gmail
    /// sign-in.
    static let identity = "https://www.googleapis.com/auth/userinfo.email"
}

/// What one account's Calendar grant allows. Google lets the user untick
/// scopes on the consent screen, so the grant is what the token response
/// says, not what was asked for.
struct CalendarGrant: Equatable, Sendable {
    let scopes: Set<String>

    init(scopes: Set<String>) {
        self.scopes = scopes.filter { $0.hasPrefix(CalendarScope.prefix + "calendar") }
    }

    /// The token response's space-separated `scope` field. Nil or empty
    /// means nothing usable was granted.
    init(grantedScopeField field: String?) {
        self.init(scopes: Set((field ?? "").split(whereSeparator: \.isWhitespace).map(String.init)))
    }

    var isEmpty: Bool { scopes.isEmpty }

    /// freebusy.query: calendar.freebusy, calendar.events.freebusy,
    /// calendar.readonly or calendar (not calendar.events).
    var canReadAvailability: Bool {
        !scopes.isDisjoint(with: [CalendarScope.eventsFreeBusy, CalendarScope.freeBusy,
                                   CalendarScope.readOnly, CalendarScope.full])
    }

    /// events.list with event details.
    var canReadEvents: Bool {
        !scopes.isDisjoint(with: [CalendarScope.events, CalendarScope.eventsReadOnly,
                                   CalendarScope.readOnly, CalendarScope.full])
    }

    /// events.patch (the user's own answer) and events.import.
    var canWriteEvents: Bool {
        !scopes.isDisjoint(with: [CalendarScope.events, CalendarScope.full])
    }

    /// calendarList.list.
    var canListCalendars: Bool {
        !scopes.isDisjoint(with: [CalendarScope.calendarListReadOnly, CalendarScope.readOnly,
                                   CalendarScope.full])
    }

    func allows(_ capability: CalendarCapability) -> Bool {
        switch capability {
        case .availability: return canReadAvailability
        case .events: return canReadEvents
        case .writeEvents: return canWriteEvents
        case .calendarList: return canListCalendars
        }
    }
}

enum CalendarCapability: String, Sendable {
    case availability, events, writeEvents, calendarList
}

/// One account's Calendar state, as every caller must handle it.
enum CalendarAccessState: Equatable, Sendable {
    /// The build has no Calendar integration (`CalendarFeatures`).
    case switchedOff
    /// The user never connected Calendar for this account, withdrew it, or
    /// Google no longer accepts the grant. Mail works exactly as before.
    case notGranted
    case granted(CalendarGrant)

    static func resolve(enabled: Bool, hasToken: Bool, grant: CalendarGrant?) -> CalendarAccessState {
        guard enabled else { return .switchedOff }
        guard hasToken, let grant, !grant.isEmpty else { return .notGranted }
        return .granted(grant)
    }

    var grant: CalendarGrant? {
        if case .granted(let grant) = self { return grant }
        return nil
    }
}

/// The separate Calendar sign-in. Desktop apps cannot extend an existing
/// grant (Google: "Incremental authorization is not supported for installed
/// apps"), so Calendar is a second consent with only the Calendar scopes and
/// its own refresh token. The Gmail sign-in and its token never change; an
/// account without Calendar loses nothing.
enum CalendarAuthorization {
    /// The Calendar refresh token's Keychain key, next to the Gmail one
    /// (`refreshToken.<account>`).
    static func keychainKey(accountId: String) -> String {
        "calendarRefreshToken.\(accountId)"
    }

    struct Tokens: Sendable {
        var refreshToken: String
        var accessToken: String
        /// The token response's `scope` field.
        var grantedScopes: String?
    }

    /// The steps the request takes, injected so tests run without Google,
    /// a browser or the Keychain.
    struct Steps: Sendable {
        /// The browser consent for exactly these scopes, for this account.
        var authorize: @Sendable (_ scopes: [String], _ loginHint: String) async throws -> Tokens
        /// The address the new access token belongs to.
        var signedInEmail: @Sendable (_ accessToken: String) async throws -> String
        /// Stores the refresh token (Keychain in the app).
        var saveRefreshToken: @Sendable (_ token: String, _ accountId: String) throws -> Void
    }

    /// Asks Google for Calendar access for one account. Only on an explicit
    /// user action; never at launch, at sign-in or from sync.
    ///
    /// Refuses with the switch off before anything runs (no listener, no
    /// browser). The new token is kept only when it belongs to `accountId`
    /// and grants something usable.
    static func request(accountId: String,
                        scopes: [String] = CalendarScope.recommended,
                        enabled: Bool = CalendarFeatures.isEnabled,
                        steps: Steps) async throws -> CalendarGrant {
        guard enabled else { throw CalendarError.switchedOff }
        let tokens = try await steps.authorize(scopes + [CalendarScope.identity], accountId)
        let email = try await steps.signedInEmail(tokens.accessToken)
        guard email.caseInsensitiveCompare(accountId) == .orderedSame else {
            throw CalendarError.wrongAccount
        }
        let grant = CalendarGrant(grantedScopeField: tokens.grantedScopes)
        guard !grant.isEmpty else { throw CalendarError.notGranted(nil) }
        try steps.saveRefreshToken(tokens.refreshToken, accountId)
        return grant
    }
}

extension CalendarAuthorization {
    /// The address in a userinfo response, only from a 200 that names one.
    /// Pure, for the hostless tests.
    static func email(fromUserInfo data: Data, response: URLResponse) throws -> String {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw status == 401 ? CalendarError.notGranted(nil)
                                : CalendarError.http(status, reason: CalendarError.reason(in: data))
        }
        guard let email = (try? GoogleUserInfo.decode(data))?.email, !email.isEmpty else {
            throw CalendarError.badResponse
        }
        return email
    }
}

extension CalendarAuthorization.Steps {
    /// The app's steps: the loopback OAuth flow, the userinfo lookup and
    /// the Keychain.
    static let live = CalendarAuthorization.Steps(
        authorize: { scopes, hint in
            let token = try await OAuthService().authorize(scopes: scopes, loginHint: hint)
            guard let refresh = token.refresh_token else {
                throw OAuthError.tokenExchangeFailed("no refresh_token returned")
            }
            return .init(refreshToken: refresh, accessToken: token.access_token,
                         grantedScopes: token.scope)
        },
        signedInEmail: { access in
            var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await GoogleHTTP.session.data(for: req)
            return try CalendarAuthorization.email(fromUserInfo: data, response: response)
        },
        saveRefreshToken: { token, accountId in
            try Keychain.set(token, forKey: CalendarAuthorization.keychainKey(accountId: accountId))
        })
}
