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
                                "-sidebar.more.expanded", "NO", "-sidebar.categories.expanded", "NO",
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
        let vendors = el("sidebar.label.\(account).Label_vendors")
        let clients = el("sidebar.label.\(account).Label_clients")
        XCTAssertTrue(vendors.waitForExistence(timeout: 5))
        log += "vendors.frame=\(vendors.frame) clients.frame=\(clients.frame)\n"
        log += "outlineRows=\(app.outlineRows.count)\n"
        for (i, r) in app.outlineRows.allElementsBoundByIndex.enumerated() {
            log += "row\(i) frame=\(r.frame) triangles=\(r.disclosureTriangles.count) id=\(r.identifier)\n"
        }
        for (i, t) in app.disclosureTriangles.allElementsBoundByIndex.enumerated() {
            log += "tri\(i) frame=\(t.frame)\n"
        }
        let row = app.outlineRows.containing(.any, identifier: vendors.identifier).firstMatch
        log += "queryRow.frame=\(row.frame) exists=\(row.exists)\n"
        let tri = row.disclosureTriangles.firstMatch
        log += "queryTriangle.frame=\(tri.frame) exists=\(tri.exists)\n"
        tri.click()
        Thread.sleep(forTimeInterval: 2)
        log += "after click: aws=\(el("sidebar.label.\(account).Label_vendors_aws").exists) "
            + "acme=\(el("sidebar.label.\(account).Label_clients_acme").exists)\n"
        log += "vendors.frame=\(vendors.frame) clients.frame=\(clients.frame)\n"
        XCTFail("DIAG\n" + log)
    }
}
