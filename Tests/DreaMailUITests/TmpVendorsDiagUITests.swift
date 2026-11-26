import XCTest

/// TEMPORARY diagnostics (removed before merge).
final class TmpVendorsDiagUITests: XCTestCase {
    private let account = "you@example.com"
    func testDiag() {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO", "-threadOpenStyle", "readingPane",
                                "-sidebar.more.expanded", "NO",
                                "-sidebar.labels.expanded.\(account)", "()"]
        app.terminate(); app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        func el(_ id: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: id).firstMatch
        }
        var log = ""
        let add = el("sidebar.labels.add")
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        log += "add type=\(add.elementType.rawValue) frame=\(add.frame) hittable=\(add.isHittable)\n"
        let named = app.buttons["Create new label"]
        log += "button by label exists=\(named.exists) frame=\(named.frame)\n"
        for b in app.buttons.allElementsBoundByIndex.prefix(40) where b.frame.minY > 470 && b.frame.minY < 500 && b.frame.minX < 320 {
            log += "btn id=\(b.identifier) lbl=\(b.label) f=\(b.frame)\n"
        }
        for dx in [0.97, 0.94, 0.90, 0.85] {
            add.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).click()
            Thread.sleep(forTimeInterval: 1.5)
            let up = el("newLabel.name").exists
            log += "click dx=\(dx): sheet=\(up) sheets=\(app.sheets.count) textFields=\(app.textFields.count)\n"
            if up { break }
        }
        if named.exists {
            named.click(); Thread.sleep(forTimeInterval: 1.5)
            log += "named click: sheet=\(el("newLabel.name").exists)\n"
        }
        XCTFail("DIAG\n" + log)
    }
}
