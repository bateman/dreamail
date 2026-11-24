import AppKit
import SwiftUI
import XCTest

/// The accent colour setting: the stored preference, conversion from the
/// system colour picker, and the one contrast rule (`AccentPalette`) for
/// drawing with any accent the owner can pick.
final class AccentColorTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AccentColorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Preference

    func testDefaultIsTheDefaultPalette() {
        XCTAssertNil(AccentPreference.read(defaults))
        XCTAssertNil(defaults.object(forKey: AccentPreference.storageKey))
        XCTAssertFalse(MailAccent(custom: AccentPreference.read(defaults)).isCustom)
        XCTAssertEqual(MailAccent.default, MailAccent(custom: nil))
    }

    func testStoreReadAndReset() {
        AccentPreference.write(" #D0201A ", to: defaults)
        XCTAssertEqual(defaults.string(forKey: AccentPreference.storageKey), "#d0201a",
                       "stored normalized as #rrggbb")
        XCTAssertEqual(AccentPreference.read(defaults), LabelRGB(hex: 0xD0201A))
        XCTAssertTrue(MailAccent(custom: AccentPreference.read(defaults)).isCustom)

        AccentPreference.reset(defaults)
        XCTAssertNil(defaults.object(forKey: AccentPreference.storageKey))
        XCTAssertNil(AccentPreference.read(defaults))

        AccentPreference.write("#123456", to: defaults)
        AccentPreference.write(nil, to: defaults)
        XCTAssertNil(defaults.object(forKey: AccentPreference.storageKey), "nil resets")
    }

    func testMalformedStoredValueMeansDefault() {
        for raw in ["", "red", "#12345", "#1234567", "#gggggg", "12 34 56",
                    "rgb(1,2,3)", "#ff0000; DROP", "#ÄÄÄÄÄÄ"] {
            defaults.set(raw, forKey: AccentPreference.storageKey)
            XCTAssertNil(AccentPreference.read(defaults), raw)
            XCTAssertEqual(AccentPreference.storedValue(raw), "", raw)
        }
        // A number or data under the key (an edited plist) is not a colour.
        defaults.set(42, forKey: AccentPreference.storageKey)
        XCTAssertNil(AccentPreference.read(defaults))
        defaults.set(Data([1, 2, 3]), forKey: AccentPreference.storageKey)
        XCTAssertNil(AccentPreference.read(defaults))
        // Malformed input to write resets instead of storing it.
        AccentPreference.write("#abcdef", to: defaults)
        AccentPreference.write("not a colour", to: defaults)
        XCTAssertNil(defaults.object(forKey: AccentPreference.storageKey))
    }

    func testBareHexWithoutHashIsAccepted() {
        XCTAssertEqual(AccentPreference.custom(raw: "00AAff"), LabelRGB(hex: 0x00AAFF))
        XCTAssertEqual(AccentPreference.storedValue("00AAff"), "#00aaff")
    }

    func testPresetsAreValidAccents() {
        XCTAssertFalse(AccentPreference.presets.isEmpty)
        for preset in AccentPreference.presets {
            XCTAssertNotNil(AccentPreference.custom(raw: preset.hex), preset.name)
        }
        XCTAssertFalse(AccentPreference.presets.contains { $0.name == "Gray" })
    }

    func testHexStringRoundTrips() {
        for value: UInt32 in [0x000000, 0xFFFFFF, 0xD0201A, 0x0064E1, 0x808080] {
            let rgb = LabelRGB(hex: value)
            XCTAssertEqual(LabelRGB(hexString: rgb.hexString), rgb)
            XCTAssertEqual(rgb.hexString, AccountLabelColor.hex(value))
        }
    }

    // MARK: - Picker conversion

    func testPickerColorsConvertToSRGBHex() throws {
        // sRGB
        XCTAssertEqual(PickedColor.hex(from: NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)),
                       "#ff8000")
        // Alpha is ignored (the well has no opacity, but a pasted colour may).
        XCTAssertEqual(PickedColor.hex(from: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.3)),
                       "#0000ff")
        // Display P3: converted, and a wide-gamut red lands on the sRGB edge.
        let p3 = try XCTUnwrap(PickedColor.hex(from: NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)))
        let rgb = try XCTUnwrap(LabelRGB(hexString: p3))
        XCTAssertEqual(rgb.r, 1, accuracy: 0.001)
        XCTAssertLessThan(rgb.g, 0.15)
        XCTAssertLessThan(rgb.b, 0.15)
        // A P3 colour inside sRGB keeps its sRGB value.
        let inside = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let viaP3 = try XCTUnwrap(inside.usingColorSpace(.displayP3))
        XCTAssertEqual(PickedColor.hex(from: viaP3), "#336699")
        // Greys from grey colour spaces.
        XCTAssertEqual(PickedColor.hex(from: NSColor(white: 0, alpha: 1)), "#000000")
        XCTAssertEqual(PickedColor.hex(from: NSColor(white: 1, alpha: 1)), "#ffffff")
        let mid = try XCTUnwrap(PickedColor.hex(from: NSColor(genericGamma22White: 0.5, alpha: 1)))
        let midRGB = try XCTUnwrap(LabelRGB(hexString: mid))
        XCTAssertEqual(midRGB.r, midRGB.g, accuracy: 0.004)
        XCTAssertEqual(midRGB.g, midRGB.b, accuracy: 0.004)
        // SwiftUI colours go through the same conversion.
        XCTAssertEqual(PickedColor.hex(from: Color(.sRGB, red: 0, green: 1, blue: 0)), "#00ff00")
        // The account label colour uses the shared conversion.
        XCTAssertEqual(AccountLabelColor.hex(from: NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)),
                       "#ff8000")
    }

    func testPickerEchoDoesNotTurnDefaultIntoAPick() {
        // Opening the well echoes the shown colour (the default blue).
        let shown = AccentPalette.defaultAccent(.light)
        let echo = NSColor(srgbRed: shown.r, green: shown.g, blue: shown.b, alpha: 1)
        XCTAssertNil(PickedColor.pickedHex(echo, shown: shown.hexString))
        XCTAssertNil(PickedColor.pickedHex(Color(shown), shown: shown.hexString))
        // A real pick is returned normalized.
        XCTAssertEqual(PickedColor.pickedHex(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                                             shown: shown.hexString), "#ff0000")
    }

    // MARK: - Contrast rule

    /// System blue, the default blue, yellow, white, black, mid grey,
    /// saturated red and green, a pale pastel and a dark navy.
    private let spread: [(String, UInt32)] = [
        ("system blue", 0x007AFF), ("highlight blue", 0x0064E1), ("default blue", 0x2383E2),
        ("yellow", 0xFFCC00), ("white", 0xFFFFFF), ("black", 0x000000),
        ("mid grey", 0x808080), ("red", 0xFF0000), ("green", 0x00FF00),
        ("system red", 0xFF3B30), ("system green", 0x34C759), ("pastel", 0xF2E6FF),
        ("navy", 0x0A1A3C), ("near white", 0xFAFAFA), ("near black", 0x050505),
    ]

    func testTextOnTheFillIsWhiteOrBlackAndReadable() {
        for (name, hex) in spread {
            let accent = LabelRGB(hex: hex)
            for appearance in LabelPillStyle.Appearance.allCases {
                let palette = AccentPalette.resolve(accent, appearance: appearance)
                XCTAssertEqual(palette.fill, accent, "\(name): the fill is the pick, unmodified")
                XCTAssertTrue(palette.onFill == .white || palette.onFill == .black, name)
                XCTAssertGreaterThanOrEqual(palette.onFill.contrast(with: palette.fill), 4.5,
                                            "\(name) \(appearance)")
            }
        }
        // White wherever white is readable (as macOS draws selected rows).
        XCTAssertEqual(AccentPalette.onFill(LabelRGB(hex: 0x0064E1)), .white)
        XCTAssertEqual(AccentPalette.onFill(LabelRGB(hex: 0xD0201A)), .white)
        XCTAssertEqual(AccentPalette.onFill(LabelRGB(hex: 0xFFCC00)), .black)
        XCTAssertEqual(AccentPalette.onFill(LabelRGB(hex: 0xFFFFFF)), .black)
        XCTAssertEqual(AccentPalette.onFill(LabelRGB(hex: 0x000000)), .white)
    }

    func testForegroundIsDistinguishableOnEverySurface() {
        for (name, hex) in spread {
            let accent = LabelRGB(hex: hex)
            for appearance in LabelPillStyle.Appearance.allCases {
                let fg = AccentPalette.resolve(accent, appearance: appearance).foreground
                for surface in AccentPalette.surfaces(appearance) {
                    XCTAssertGreaterThanOrEqual(fg.contrast(with: surface), 2.99,
                                                "\(name) \(appearance) on \(surface.hexString): \(fg.hexString)")
                }
            }
        }
    }

    func testForegroundKeepsTheHueAndMovesOnlyWhenNeeded() {
        for (name, hex) in spread {
            let accent = LabelRGB(hex: hex)
            for appearance in LabelPillStyle.Appearance.allCases {
                let fg = AccentPalette.resolve(accent, appearance: appearance).foreground
                let worst = AccentPalette.surfaces(appearance).map { accent.contrast(with: $0) }.min()!
                if worst >= 3 {
                    XCTAssertEqual(fg, accent, "\(name) \(appearance): already readable, unchanged")
                    continue
                }
                let before = HSL(accent), after = HSL(fg)
                if before.s > 0.05 {
                    let dh = abs(before.h - after.h)
                    XCTAssertLessThan(min(dh, 1 - dh), 0.01, "\(name) \(appearance): hue kept")
                    XCTAssertEqual(after.s, before.s, accuracy: 0.02, "\(name): saturation kept")
                }
                // Darker on light surfaces, lighter on dark ones.
                if appearance == .light {
                    XCTAssertLessThan(after.l, before.l, name)
                } else {
                    XCTAssertGreaterThan(after.l, before.l, name)
                }
                // The smallest move: a step back toward the pick falls short.
                let back = HSL(fg).with(l: after.l + (before.l - after.l) * 0.05).rgb
                let backWorst = AccentPalette.surfaces(appearance).map { back.contrast(with: $0) }.min()!
                XCTAssertLessThan(backWorst, 3.05, "\(name) \(appearance): moved too far")
            }
        }
        // Concretely: yellow darkens on white, navy lightens on dark.
        let yellow = AccentPalette.resolve(LabelRGB(hex: 0xFFCC00), appearance: .light).foreground
        XCTAssertLessThan(yellow.luminance, LabelRGB(hex: 0xFFCC00).luminance)
        let navy = AccentPalette.resolve(LabelRGB(hex: 0x0A1A3C), appearance: .dark).foreground
        XCTAssertGreaterThan(navy.luminance, LabelRGB(hex: 0x0A1A3C).luminance)
        // White on light surfaces becomes a grey; black on dark ones too.
        let white = AccentPalette.resolve(.white, appearance: .light).foreground
        XCTAssertEqual(white.r, white.g, accuracy: 0.001)
        XCTAssertLessThan(white.r, 0.6)
    }

    func testDefaultPaletteIsUnchanged() {
        XCTAssertEqual(AccentPalette.resolve(nil, appearance: .light),
                       AccentPalette(fill: LabelRGB(hex: 0x2383E2), onFill: .white,
                                     foreground: LabelRGB(hex: 0x2383E2)))
        XCTAssertEqual(AccentPalette.resolve(nil, appearance: .dark),
                       AccentPalette(fill: LabelRGB(hex: 0x2E9BE8), onFill: .white,
                                     foreground: LabelRGB(hex: 0x2E9BE8)))
        let accent = MailAccent.default
        XCTAssertEqual(accent.palette(.light).fill, LabelRGB(hex: 0x2383E2))
    }

    func testAdaptiveColorsResolvePerAppearance() throws {
        let accent = MailAccent(custom: LabelRGB(hex: 0xFFCC00))
        let light = try XCTUnwrap(AppearanceColorSupport.resolve(accent.nsColor(\.foreground), in: .aqua))
        let dark = try XCTUnwrap(AppearanceColorSupport.resolve(accent.nsColor(\.foreground), in: .darkAqua))
        XCTAssertEqual(PickedColor.hex(from: light),
                       AccentPalette.resolve(LabelRGB(hex: 0xFFCC00), appearance: .light).foreground.hexString)
        XCTAssertEqual(PickedColor.hex(from: dark), "#ffcc00", "yellow is readable on dark")
        let fill = try XCTUnwrap(AppearanceColorSupport.resolve(accent.nsFill, in: .aqua))
        XCTAssertEqual(PickedColor.hex(from: fill), "#ffcc00", "the fill is never adjusted")
        let onFill = try XCTUnwrap(AppearanceColorSupport.resolve(accent.nsColor(\.onFill), in: .darkAqua))
        XCTAssertEqual(PickedColor.hex(from: onFill), "#000000")
    }

    // MARK: - On the selection

    func testSelectionUsesTheAccentInEffect() {
        let red = LabelRGB(hex: 0xD0201A)
        for appearance in LabelPillStyle.Appearance.allCases {
            let custom = LabelPillStyle.surfaceColors(.selection, appearance, selectionFill: red)
            XCTAssertEqual(custom, [red, LabelPillStyle.inactiveSelection(appearance)])
            // Default: the system highlight, as before the setting.
            XCTAssertEqual(LabelPillStyle.surfaceColors(.selection, appearance),
                           [LabelPillStyle.systemSelection(appearance),
                            LabelPillStyle.inactiveSelection(appearance)])
        }
        // A red label chip on a red selection needs its outline; on the
        // system blue it does not.
        let redChip = LabelColors(background: "#cc3a21", text: "#ffffff")
        XCTAssertTrue(LabelPillStyle.resolve(redChip, appearance: .light, surface: .selection,
                                             selectionFill: red).needsBorder)
        XCTAssertFalse(LabelPillStyle.resolve(redChip, appearance: .light, surface: .selection).needsBorder)
        // A blue chip on a red selection stands out.
        let blueChip = LabelColors(background: "#285bac", text: nil)
        XCTAssertFalse(LabelPillStyle.resolve(blueChip, appearance: .light, surface: .selection,
                                              selectionFill: red).needsBorder)
    }

    func testSelectionTextFollowsTheRuleForEveryAccent() {
        // Selected rows draw text and glyphs in `onFill`; inactive ones in
        // the label colour on grey (not the rule's business).
        for (name, hex) in spread {
            let fill = LabelRGB(hex: hex)
            let on = AccentPalette.onFill(fill)
            XCTAssertGreaterThanOrEqual(on.contrast(with: fill), 4.5, name)
        }
    }

    func testSelectionDrawingStates() {
        // Custom accent: emphasized → the app paints the accent; otherwise
        // the system's grey shows. Default accent: the system, always.
        let red = MailAccent(custom: LabelRGB(hex: 0xD0201A))
        XCTAssertEqual(SelectionHighlight.resolve(accent: red, emphasized: true), .accent)
        XCTAssertEqual(SelectionHighlight.resolve(accent: red, emphasized: false), .system)
        XCTAssertEqual(SelectionHighlight.resolve(accent: .default, emphasized: true), .system)
        XCTAssertEqual(SelectionHighlight.resolve(accent: .default, emphasized: false), .system)
        // Ink on the selection: onFill only where the app paints.
        XCTAssertNil(SelectionInk.color(selected: true, prominence: .increased, accent: .default))
        XCTAssertNil(SelectionInk.color(selected: true, prominence: .standard, accent: red))
        XCTAssertNil(SelectionInk.color(selected: false, prominence: .increased, accent: red))
        XCTAssertNotNil(SelectionInk.color(selected: true, prominence: .increased, accent: red))
    }
}
