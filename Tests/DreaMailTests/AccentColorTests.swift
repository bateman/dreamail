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

    /// What the window roots read: the stored string under the key, as
    /// `@AppStorage` hands it over.
    private func stored() -> LabelRGB? {
        AccentPreference.custom(raw: defaults.string(forKey: AccentPreference.storageKey))
    }

    func testDefaultIsTheDefaultPalette() {
        XCTAssertNil(defaults.object(forKey: AccentPreference.storageKey))
        XCTAssertNil(stored())
        XCTAssertFalse(MailAccent(custom: stored()).isCustom)
        XCTAssertEqual(MailAccent.default, MailAccent(custom: nil))
    }

    func testStoredPickIsReadBackAndEmptyResets() {
        // The Settings row stores `storedValue(_:)`; "" is Default.
        defaults.set(AccentPreference.storedValue(" #D0201A "), forKey: AccentPreference.storageKey)
        XCTAssertEqual(defaults.string(forKey: AccentPreference.storageKey), "#d0201a",
                       "stored normalized as #rrggbb")
        XCTAssertEqual(stored(), LabelRGB(hex: 0xD0201A))
        XCTAssertTrue(MailAccent(custom: stored()).isCustom)
        defaults.set(AccentPreference.storedValue(nil), forKey: AccentPreference.storageKey)
        XCTAssertNil(stored())
        XCTAssertFalse(MailAccent(custom: stored()).isCustom)
    }

    func testMalformedStoredValueMeansDefault() {
        for raw in ["", "red", "#12345", "#1234567", "#gggggg", "12 34 56",
                    "rgb(1,2,3)", "#ff0000; DROP", "#ÄÄÄÄÄÄ"] {
            defaults.set(raw, forKey: AccentPreference.storageKey)
            XCTAssertNil(stored(), raw)
            XCTAssertEqual(AccentPreference.storedValue(raw), "", raw)
        }
        // A number or data under the key (an edited plist) is not a colour.
        defaults.set(42, forKey: AccentPreference.storageKey)
        XCTAssertNil(stored())
        defaults.set(Data([1, 2, 3]), forKey: AccentPreference.storageKey)
        XCTAssertNil(stored())
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
    }

    func testPickerEchoDoesNotTurnDefaultIntoAPick() {
        // Opening the well echoes the shown colour (the default blue).
        let shown = AccentPalette.defaultAccent(.light)
        let echo = NSColor(srgbRed: shown.r, green: shown.g, blue: shown.b, alpha: 1)
        XCTAssertNil(PickedColor.pickedHex(echo, shown: shown.hexString))
        XCTAssertNil(PickedColor.pickedHex(Color(.sRGB, red: shown.r, green: shown.g, blue: shown.b),
                                           shown: shown.hexString))
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

    func testTextReachesFourAndAHalfOnSurfacesAndTheChipWash() {
        for (name, hex) in spread {
            let accent = LabelRGB(hex: hex)
            for appearance in LabelPillStyle.Appearance.allCases {
                let text = AccentPalette.resolve(accent, appearance: appearance).text
                for surface in AccentPalette.textSurfaces(accent, appearance) {
                    XCTAssertGreaterThanOrEqual(text.contrast(with: surface), 4.49,
                                                "\(name) \(appearance) on \(surface.hexString): \(text.hexString)")
                }
            }
        }
        // Yellow as text on white is a dark ochre, darker than its glyph colour.
        let yellow = AccentPalette.resolve(LabelRGB(hex: 0xFFCC00), appearance: .light)
        XCTAssertLessThan(yellow.text.luminance, yellow.foreground.luminance)
    }

    func testControlTintKeepsTheSystemsWhiteLabelReadable() {
        // Bordered-prominent buttons draw a white label on `.tint`.
        for (name, hex) in spread {
            let accent = LabelRGB(hex: hex)
            for appearance in LabelPillStyle.Appearance.allCases {
                let control = AccentPalette.resolve(accent, appearance: appearance).control
                XCTAssertGreaterThanOrEqual(LabelRGB.white.contrast(with: control), 4.49, name)
                if accent.contrast(with: .white) >= 4.5 {
                    XCTAssertEqual(control, accent, "\(name): readable picks are used as they are")
                }
            }
        }
        // Yellow keeps its hue as a darker control colour.
        let control = AccentPalette.resolve(LabelRGB(hex: 0xFFCC00), appearance: .light).control
        let dh = abs(HSL(control).h - HSL(LabelRGB(hex: 0xFFCC00)).h)
        XCTAssertLessThan(min(dh, 1 - dh), 0.01)
    }

    func testNearGreysMoveAsGreys() {
        // #fefeff has a saturation of 1 in HSL but no visible hue: it must
        // become a grey, not a vivid periwinkle.
        let pale = LabelRGB(hex: 0xFEFEFF)
        let palette = AccentPalette.resolve(pale, appearance: .light)
        for c in [palette.foreground, palette.text] {
            XCTAssertLessThan(max(c.r, c.g, c.b) - min(c.r, c.g, c.b), 0.01, c.hexString)
        }
        // A real hue still keeps it.
        let pastel = AccentPalette.resolve(LabelRGB(hex: 0xF2E6FF), appearance: .light).foreground
        XCTAssertGreaterThan(max(pastel.r, pastel.g, pastel.b) - min(pastel.r, pastel.g, pastel.b), 0.1)
    }

    func testSelectionGetsAnOutlineWhenTheFillVanishesIntoTheSurface() {
        // White on the light rows, the dark content colour in dark mode.
        XCTAssertTrue(AccentPalette.resolve(.white, appearance: .light).selectionBorder)
        XCTAssertTrue(AccentPalette.resolve(LabelRGB(hex: 0x191919), appearance: .dark).selectionBorder)
        XCTAssertTrue(AccentPalette.resolve(.black, appearance: .dark).selectionBorder)
        XCTAssertTrue(AccentPalette.resolve(LabelRGB(hex: 0xFAFAFA), appearance: .light).selectionBorder)
        // Yellow stands out enough on white (1.5:1) and on dark.
        XCTAssertFalse(AccentPalette.resolve(LabelRGB(hex: 0xFFCC00), appearance: .light).selectionBorder)
        XCTAssertFalse(AccentPalette.resolve(LabelRGB(hex: 0xFFCC00), appearance: .dark).selectionBorder)
        // Ordinary picks, and the default palette, never get one.
        XCTAssertFalse(AccentPalette.resolve(LabelRGB(hex: 0xD0201A), appearance: .light).selectionBorder)
        XCTAssertFalse(AccentPalette.resolve(LabelRGB(hex: 0xD0201A), appearance: .dark).selectionBorder)
        XCTAssertFalse(AccentPalette.resolve(nil, appearance: .light).selectionBorder)
        // The outline (the foreground colour) itself reaches 3:1 on every row.
        for (accent, appearance) in [(LabelRGB.white, LabelPillStyle.Appearance.light),
                                     (LabelRGB(hex: 0x191919), .dark)] {
            let palette = AccentPalette.resolve(accent, appearance: appearance)
            for surface in AccentPalette.surfaces(appearance) {
                XCTAssertGreaterThanOrEqual(palette.foreground.contrast(with: surface), 2.99)
            }
        }
    }

    func testDimmedInkStaysReadableOrGoesFullStrength() {
        // White ink on a deep red keeps 4.5:1 at 80%: the emphasis is kept.
        let red = AccentPalette.resolve(LabelRGB(hex: 0x8B0000), appearance: .light)
        XCTAssertEqual(red.inkOpacity(0.8), 0.8)
        // White on the highlight-blue pick only just reaches 4.5:1: dimmed
        // it would not, so it is drawn at full strength.
        let blue = AccentPalette.resolve(LabelRGB(hex: 0x0064E1), appearance: .light)
        XCTAssertEqual(blue.inkOpacity(0.8), 1)
        for (name, hex) in spread {
            let palette = AccentPalette.resolve(LabelRGB(hex: hex), appearance: .light)
            for emphasis in [0.6, 0.75, 0.8, 0.9] {
                let alpha = palette.inkOpacity(emphasis)
                let drawn = palette.fill.composited(under: palette.onFill, alpha: alpha)
                XCTAssertGreaterThanOrEqual(drawn.contrast(with: palette.fill), 4.5, "\(name) at \(emphasis)")
            }
        }
    }

    func testDefaultPaletteIsUnchanged() {
        for (appearance, blue) in [(LabelPillStyle.Appearance.light, LabelRGB(hex: 0x2383E2)),
                                   (.dark, LabelRGB(hex: 0x2E9BE8))] {
            XCTAssertEqual(AccentPalette.resolve(nil, appearance: appearance),
                           AccentPalette(fill: blue, onFill: .white, foreground: blue, text: blue,
                                         control: blue, selectionBorder: false))
        }
        XCTAssertEqual(MailAccent.default.palette(.light).fill, LabelRGB(hex: 0x2383E2))
    }

    func testPalettesAreResolvedOnceWhenTheAccentIsMade() {
        let yellow = LabelRGB(hex: 0xFFCC00)
        let accent = MailAccent(custom: yellow)
        XCTAssertEqual(accent.light, AccentPalette.resolve(yellow, appearance: .light))
        XCTAssertEqual(accent.dark, AccentPalette.resolve(yellow, appearance: .dark))
        XCTAssertEqual(accent, MailAccent(custom: yellow))
        XCTAssertNotEqual(accent, MailAccent.default)
    }

    func testAdaptiveColorsResolvePerAppearance() throws {
        let accent = MailAccent(custom: LabelRGB(hex: 0xFFCC00))
        let light = try XCTUnwrap(AppearanceColorSupport.resolve(accent.nsColor(\.foreground), in: .aqua))
        let dark = try XCTUnwrap(AppearanceColorSupport.resolve(accent.nsColor(\.foreground), in: .darkAqua))
        XCTAssertEqual(PickedColor.hex(from: light),
                       AccentPalette.resolve(LabelRGB(hex: 0xFFCC00), appearance: .light).foreground.hexString)
        XCTAssertEqual(PickedColor.hex(from: dark), "#ffcc00", "yellow is readable on dark")
        let fill = try XCTUnwrap(AppearanceColorSupport.resolve(accent.nsColor(\.fill), in: .aqua))
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
        // A black label chip on a near-black selection needs its outline;
        // on the system blue (and the inactive grey) it does not.
        let nearBlack = LabelRGB(hex: 0x1A1A1A)
        let blackChip = LabelColors(background: "#000000", text: "#ffffff")
        XCTAssertTrue(LabelPillStyle.resolve(blackChip, appearance: .light, surface: .selection,
                                             selectionFill: nearBlack).needsBorder)
        XCTAssertFalse(LabelPillStyle.resolve(blackChip, appearance: .light, surface: .selection).needsBorder)
        // Its outline contrasts with the near-black highlight.
        let style = LabelPillStyle.resolve(blackChip, appearance: .light, surface: .selection,
                                           selectionFill: nearBlack)
        XCTAssertGreaterThanOrEqual(style.border.contrast(with: nearBlack), 3)
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

    func testSelectionPaintingStates() {
        let red = MailAccent(custom: LabelRGB(hex: 0xD0201A))
        // Painted only with a custom accent, and only on macOS 26 and later
        // (where the mechanism is verified); the default never paints.
        XCTAssertFalse(MailAccent.default.paintsSelection)
        if #available(macOS 26, *) {
            XCTAssertTrue(red.paintsSelection)
            // Ink: onFill on the emphasized selection only.
            XCTAssertNotNil(SelectionInk.color(prominence: .increased, accent: red))
        } else {
            XCTAssertFalse(red.paintsSelection)
            XCTAssertNil(SelectionInk.color(prominence: .increased, accent: red))
        }
        XCTAssertNil(SelectionInk.color(prominence: .standard, accent: red))
        XCTAssertNil(SelectionInk.color(prominence: .increased, accent: .default))
    }

    /// The ink a selected row draws on the painted accent, per accent: the
    /// UI suite renders the red case (white ink); the yellow one (black
    /// ink) is the same drawing path, so the rule is checked here.
    func testSelectionInkOnRedIsWhiteAndOnYellowIsBlack() throws {
        for (hex, ink) in [(0xD0201A, "#ffffff"), (0xFFCC00, "#000000")] {
            let accent = MailAccent(custom: LabelRGB(hex: hex))
            if #available(macOS 26, *) {
                XCTAssertNotNil(SelectionInk.color(prominence: .increased, accent: accent),
                                "a selected row draws the ink on \(hex)")
            }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let drawn = try XCTUnwrap(AppearanceColorSupport.resolve(accent.nsColor(\.onFill), in: appearance))
                XCTAssertEqual(PickedColor.hex(from: drawn), ink, "ink on \(String(hex, radix: 16)) in \(appearance.rawValue)")
            }
        }
    }
}
