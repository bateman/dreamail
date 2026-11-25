import Foundation

/// Build-time switch for the Google Calendar integration (step 4A).
///
/// Off in the shipped configuration, the same way as `AIFeatures`: the value
/// comes from the build setting `DREAMAIL_CALENDAR`, which Info.plist expands
/// under `infoKey`; the tracked `Config/Signing.xcconfig` leaves it empty, and
/// only an untracked `Config/Local.xcconfig` (or the `xcodebuild` command
/// line) can set it to `YES`. `make install` and `make release` always take
/// the tracked value. It is not a preference: a stray `defaults write` must
/// not be able to ask Google for a new scope or reach the Calendar API.
///
/// With the switch off:
/// - no Calendar surface exists (there is none yet: the scope and the
///   features are still being decided);
/// - `CalendarTransport.live`, the one network path to the Calendar API,
///   refuses before anything is sent;
/// - `CalendarAuthorization.request` refuses before a listener or a browser
///   opens, so the Calendar scope is never asked for;
/// - `CalendarTokenSource` refuses before the Keychain is read or a token
///   is refreshed.
///
/// The default Gmail sign-in (`OAuthConfig.scopes`) never includes a
/// Calendar scope, whatever the switch says: Calendar is a separate,
/// explicit grant (`CalendarAuthorization`).
enum CalendarFeatures {
    /// Info.plist key the build setting expands into.
    static let infoKey = "DreaMailCalendar"

    /// The state this process was built with. Read once.
    static let isEnabled: Bool = configured(in: Bundle.main.infoDictionary)

    /// True only for an explicit yes, like `AIFeatures.isOn`.
    static func configured(in infoDictionary: [String: Any]?) -> Bool {
        AIFeatures.isOn(infoDictionary?[infoKey] as? String)
    }

    /// What a refused Calendar action says, when it says anything.
    static let disabledMessage = "Google Calendar is turned off in this build."
}
