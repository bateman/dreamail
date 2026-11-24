import XCTest

/// How an account is presented: the title rule (label, else sender name,
/// else address) and the ring around its avatar in the label color.
final class AccountRingStyleTests: XCTestCase {

    // MARK: - Title

    func testTitleRule() {
        let id = "a@x.com"
        let cases: [(label: String, sender: String, expected: String, why: String)] = [
            ("Lavoro", "Fabio Calefato", "Lavoro", "label set: the label, not the name"),
            ("Lavoro", "", "Lavoro", "label without a sender name"),
            ("  Lavoro ", "Fabio", "Lavoro", "label trimmed"),
            ("", "Fabio Calefato", "Fabio Calefato", "no label: the sender name"),
            ("   ", "Fabio", "Fabio", "blank label counts as unset"),
            ("a@x.com", "Fabio", "Fabio", "label equal to the address is not a label"),
            ("A@X.COM", "Fabio", "Fabio", "address compared case-insensitively"),
            ("", "", "a@x.com", "nothing set: the address"),
            ("a@x.com", "", "a@x.com", "label is the address, no sender: the address"),
            ("", "  ", "a@x.com", "blank sender counts as unset"),
            ("Jane", "Jane", "Jane", "label equal to the sender name"),
        ]
        for c in cases {
            XCTAssertEqual(AccountLabelColor.title(displayName: c.label, senderName: c.sender,
                                                   accountId: id), c.expected, c.why)
        }
    }

    func testTitleFromAccount() {
        XCTAssertEqual(AccountLabelColor.title(Account(
            id: "a@x.com", displayName: "Fund", historyId: nil, lastSyncAt: nil,
            senderName: "Jane")), "Fund")
        XCTAssertEqual(AccountLabelColor.title(Account(
            id: "a@x.com", displayName: "a@x.com", historyId: nil, lastSyncAt: nil,
            senderName: "Jane")), "Jane")
        XCTAssertEqual(AccountLabelColor.title(Account(
            id: "a@x.com", displayName: "", historyId: nil, lastSyncAt: nil)), "a@x.com")
    }

    // MARK: - Ring color

    func testRingUsesTheChosenColor() {
        for appearance in LabelPillStyle.Appearance.allCases {
            for surface in AccountRingStyle.Surface.allCases {
                let style = AccountRingStyle.resolve(storedHex: "#3C78D8", accountId: "a@x.com",
                                                     appearance: appearance, surface: surface)
                XCTAssertEqual(style.color, LabelRGB(hex: 0x3C78D8), "\(appearance) \(surface)")
            }
        }
    }

    func testRingDefaultsToTheAvatarHue() {
        for id in ["a@x.com", "fabio@example.com", "you@example.com", "z@y.org"] {
            for bad in [nil, "", "zzz", "#12345"] as [String?] {
                let style = AccountRingStyle.resolve(storedHex: bad, accountId: id,
                                                     appearance: .light, surface: .sidebar)
                XCTAssertEqual(style.color,
                               LabelRGB(hexString: AccountLabelColor.defaultHex(for: id)),
                               "\(id) \(bad ?? "nil")")
            }
        }
    }

    // MARK: - Hairline

    /// The ring is visible on every surface in both appearances: either the
    /// color itself stands out (1.5:1 against every surface color), or a
    /// neutral hairline that reaches 3:1 is drawn around it.
    func testRingIsVisibleEverywhere() {
        for appearance in LabelPillStyle.Appearance.allCases {
            for surface in AccountRingStyle.Surface.allCases {
                for hex in AccountLabelColorTests.sampleColors {
                    let style = AccountRingStyle.resolve(storedHex: hex, accountId: "a@x.com",
                                                         appearance: appearance, surface: surface)
                    XCTAssertEqual(style.color, LabelRGB(hexString: hex),
                                   "the color is never changed: \(hex)")
                    for behind in AccountRingStyle.surfaceColors(surface, appearance) {
                        if style.needsHairline {
                            XCTAssertGreaterThanOrEqual(style.hairline.contrast(with: behind), 3,
                                                        "\(hex) \(appearance) \(surface) hairline")
                        } else {
                            XCTAssertGreaterThanOrEqual(style.color.contrast(with: behind),
                                                        LabelPillStyle.minimumEdgeContrast,
                                                        "\(hex) \(appearance) \(surface) edge")
                        }
                    }
                }
            }
        }
    }

    func testHairlineOnlyForLowContrastColors() {
        func hairline(_ hex: String, _ appearance: LabelPillStyle.Appearance,
                      _ surface: AccountRingStyle.Surface) -> Bool {
            AccountRingStyle.resolve(storedHex: hex, accountId: "a@x.com",
                                     appearance: appearance, surface: surface).needsHairline
        }
        // Light: white and near-white melt into the surfaces, saturated
        // colors do not.
        XCTAssertTrue(hairline("#ffffff", .light, .sidebar))
        XCTAssertTrue(hairline("#f7f7f5", .light, .sidebar))
        XCTAssertTrue(hairline("#ffffff", .light, .popover))
        XCTAssertTrue(hairline("#fef1d1", .light, .groupedForm))
        XCTAssertFalse(hairline("#0088ff", .light, .sidebar))
        XCTAssertFalse(hairline("#000000", .light, .popover))
        // Dark: black and near-black melt in, light colors do not.
        XCTAssertTrue(hairline("#000000", .dark, .sidebar))
        XCTAssertTrue(hairline("#232323", .dark, .sidebar))
        XCTAssertTrue(hairline("#191919", .dark, .popover))
        XCTAssertTrue(hairline("#0d3472", .dark, .groupedForm))
        XCTAssertFalse(hairline("#ffffff", .dark, .sidebar))
        XCTAssertFalse(hairline("#ff8d28", .dark, .popover))
    }

    func testEveryDefaultColorIsVisibleWithoutAHairlineOnTheSidebar() {
        // The defaults follow the avatar palette: saturated system colors
        // that need no hairline on the sidebar in either appearance.
        for value in AccountLabelColor.defaultPalette {
            let hex = AccountLabelColor.hex(value)
            for appearance in LabelPillStyle.Appearance.allCases {
                let style = AccountRingStyle.resolve(storedHex: hex, accountId: "a@x.com",
                                                     appearance: appearance, surface: .sidebar)
                XCTAssertFalse(style.needsHairline, "\(hex) \(appearance)")
            }
        }
    }

    func testSidebarSurfaceMatchesTheSidebarBackground() {
        XCTAssertEqual(AccountRingStyle.surfaceColors(.sidebar, .light), [LabelRGB(hex: 0xF7F7F5)])
        XCTAssertEqual(AccountRingStyle.surfaceColors(.sidebar, .dark), [LabelRGB(hex: 0x232323)])
    }

    // MARK: - Metrics

    func testMetricsForTheHeaderAvatar() {
        let m = AccountRingMetrics(size: 28)
        XCTAssertEqual(m.size, 28)
        XCTAssertEqual(m.ringWidth, 2)
        XCTAssertEqual(m.gap, 1.5)
        XCTAssertEqual(m.hairlineWidth, 0.5)
        XCTAssertEqual(m.photoDiameter, 21)
    }

    func testMetricsForTheRowAvatar() {
        let m = AccountRingMetrics(size: 24)
        XCTAssertEqual(m.size, 24)
        XCTAssertEqual(m.ringWidth, 1.75)
        XCTAssertEqual(m.gap, 1.25)
        XCTAssertEqual(m.photoDiameter, 18)
    }

    func testMetricsKeepTheFootprintAndAVisibleGap() {
        for size in stride(from: 16.0, through: 64.0, by: 2) {
            let m = AccountRingMetrics(size: size)
            XCTAssertEqual(m.size, size, "the frame is unchanged")
            XCTAssertGreaterThanOrEqual(m.gap, 1, "ring and disc stay apart at \(size)")
            XCTAssertGreaterThanOrEqual(m.ringWidth, 1)
            XCTAssertLessThan(m.hairlineWidth, m.ringWidth, "the hairline leaves the ring visible")
            XCTAssertGreaterThan(m.photoDiameter, size * 0.6, "the photo stays the main element")
            XCTAssertEqual(m.photoDiameter + 2 * (m.ringWidth + m.gap), size, accuracy: 1e-9)
        }
    }
}
