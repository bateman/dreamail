import XCTest
import AppKit

/// The sidebar toggle never straddles two background colours: the pixels just
/// left and just right of it match, collapsed and expanded, light and dark.
final class TopBandSeamUITests: XCTestCase {
    func testLight() throws { try run(dark: false) }
    func testDark() throws { try run(dark: true) }

    private func run(dark: Bool) throws {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO", "-threadOpenStyle", "readingPane",
                                "-AppleInterfaceStyle", dark ? "Dark" : "Light"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sidebarStrip")
            .firstMatch.waitForExistence(timeout: 5), "starts collapsed")
        try check(window, "collapsed")
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composeButton")
            .firstMatch.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        try check(window, "expanded")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
    }

    private func check(_ window: XCUIElement, _ context: String) throws {
        let toggle = window.descendants(matching: .button).matching(NSPredicate(
            format: "identifier CONTAINS[c] 'sidebar' OR label CONTAINS[c] 'sidebar'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "\(context): sidebar toggle")
        let frame = window.frame
        let cg = try XCTUnwrap(window.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cg)
        let scale = Double(cg.width) / Double(frame.width)
        func pixel(_ x: CGFloat, _ y: CGFloat) -> [Int] {
            let c = rep.colorAt(x: Int(Double(x - frame.minX) * scale), y: Int(Double(y - frame.minY) * scale))?
                .usingColorSpace(.sRGB)
            guard let c else { return [] }
            return [Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)]
        }
        let y = toggle.frame.midY
        let left = pixel(toggle.frame.minX - 3, y), right = pixel(toggle.frame.maxX + 3, y)
        XCTAssertFalse(left.isEmpty)
        XCTAssertEqual(left.count, right.count)
        for (a, b) in zip(left, right) {
            XCTAssertLessThanOrEqual(abs(a - b), 2, "\(context): left \(left) vs right \(right) of the toggle")
        }
    }
}
