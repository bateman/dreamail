import Foundation

/// Build-time master switch for OpenPGP support (step 4B).
///
/// Off in the shipped configuration, on the same pattern as `AIFeatures`:
/// the value comes from the build setting `MISHMAIL_PGP`, which Info.plist
/// expands under `infoKey`; the tracked `Config/Signing.xcconfig` leaves it
/// empty, and only an untracked `Config/Local.xcconfig` (or the `xcodebuild`
/// command line) can set it to `YES`. It is not a preference.
///
/// In this step nothing in the app reads it: the code under `PGP/` is the
/// structure-only groundwork (MIME recognition, signed-bytes extraction, the
/// engine protocol and the display rules), with no crypto library, no user
/// interface and no network request. The entry points that read a message
/// (`PGPInspection`, `PGPStructure.findings`) take the state as a parameter,
/// so the tests exercise both, and with it off return before parsing or
/// calling an engine. The pure helpers under them (`RawMIME`, the display
/// rules) take no switch; a test keeps every `PGP/` type unused outside
/// `PGP/` until the step that wires it in.
enum PGPFeatures {
    /// Info.plist key the build setting expands into.
    static let infoKey = "MishMailPGP"

    /// The state this process was built with. Read once.
    static let isEnabled: Bool = configured(in: Bundle.main.infoDictionary)

    /// True only for an explicit yes. Empty, missing, an unexpanded
    /// `$(MISHMAIL_PGP)`, or anything unrecognised is off.
    static func configured(in infoDictionary: [String: Any]?) -> Bool {
        AIFeatures.isOn(infoDictionary?[infoKey] as? String)
    }
}
