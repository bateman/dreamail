import Foundation

/// Build-time master switch for OpenPGP support (step 4B).
///
/// Off in the shipped configuration, on the same pattern as `AIFeatures`:
/// the value comes from the build setting `MISHMAIL_PGP`, which Info.plist
/// expands under `infoKey`; the tracked `Config/Signing.xcconfig` leaves it
/// empty, and only an untracked `Config/Local.xcconfig` (or the `xcodebuild`
/// command line) can set it to `YES`. It is not a preference.
///
/// With it off nothing of OpenPGP runs: `PGPCenter` (the app's only way in)
/// returns from every entry point first, the message view never looks for
/// OpenPGP, and Settings has no OpenPGP pane. The library is linked either
/// way and never called. The entry points that read a message
/// (`PGPInspection`, `PGPStructure.findings`) take the state as a parameter,
/// so the tests exercise both. A test keeps the files outside `PGP/` that
/// reach into it to a fixed, gated list.
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
