import XCTest
import AppKit

/// Light: the sidebar toggle never straddles two background colours, so the
/// pixels just left and right of it match, collapsed and expanded. Dark: the
/// band keeps the rail colour (unchanged).
final class TopBandSeamUITests: XCTestCase {
    func testLight() throws { try run(dark: false) }
    func testDark() throws { try run(dark: true) }

    private func launch(dark: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO", "-threadOpenStyle", "readingPane",
                                "-appTheme", dark ? "dark" : "light"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func run(dark: Bool) throws {
        let app = launch(dark: dark)
        XCTAssertTrue(element(app, "threadRow.you@example.com:t3").waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        // Collapsed whatever an earlier suite left.
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "sidebarStrip").waitForExistence(timeout: 5), "collapsed")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        try check(window, "collapsed", dark: dark)
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "composeButton").waitForExistence(timeout: 5), "expanded")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        try check(window, "expanded", dark: dark)
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
    }

    private func check(_ window: XCUIElement, _ context: String, dark: Bool) throws {
        // The system toggle: the leftmost toolbar button right of the window
        // buttons, in the title-bar row.
        let buttons = window.toolbars.firstMatch.buttons
        var toggle: XCUIElement?
        for i in 0..<buttons.count {
            let b = buttons.element(boundBy: i)
            guard b.exists else { continue }
            if toggle == nil || b.frame.minX < toggle!.frame.minX { toggle = b }
        }
        let frame = window.frame
        let found = try XCTUnwrap(toggle, "\(context): no toolbar button")
        let t = found.frame
        let desc = "\(context): toggle \(t), window \(frame)"
        print("TopBandSeam: \(desc)")
        XCTAssertGreaterThanOrEqual(t.minX - frame.minX, 80, "right of the window buttons: \(desc)")
        XCTAssertLessThan(t.midY - frame.minY, 60, "in the title-bar row: \(desc)")

        let cg = try XCTUnwrap(window.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cg)
        let scale = Double(cg.width) / Double(frame.width)
        func pixel(_ x: CGFloat) -> [Int] {
            guard let c = rep.colorAt(x: Int(Double(x - frame.minX) * scale),
                                      y: Int(Double(t.midY - frame.minY) * scale))?.usingColorSpace(.sRGB)
            else { return [] }
            return [Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)]
        }
        let left = pixel(t.minX - 3), right = pixel(t.maxX + 3)
        XCTAssertEqual(left.count, 3, desc)
        XCTAssertEqual(right.count, 3, desc)
        guard left.count == 3, right.count == 3 else { return }
        if dark {
            // Unchanged: the band is the rail colour (1A1D23) left of the toggle.
            for (a, b) in zip(left, [0x1A, 0x1D, 0x23]) {
                XCTAssertLessThanOrEqual(abs(a - b), 2, "\(desc): left \(left) is not the rail colour")
            }
        } else {
            for (a, b) in zip(left, right) {
                XCTAssertLessThanOrEqual(abs(a - b), 2, "\(desc): left \(left) vs right \(right)")
            }
        }
    }
}
