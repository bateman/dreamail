import XCTest
import AppKit

/// The top band behind the sidebar toggle is one colour. Measured on the
/// background only, along the title-bar row, so it does not depend on where
/// the system toggle is (it sits just right of the window buttons, around
/// x = 95...130, and the old seam ran through it at x = 104).
/// Light, collapsed: no sample from x = 84 to 200 is the rail grey.
/// Dark, collapsed: unchanged, the rail colour up to the band edge.
/// Expanded: the row is only logged.
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
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let collapsed = try row(window, "collapsed")
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "composeButton").waitForExistence(timeout: 5), "expanded")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        _ = try row(window, "expanded")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])

        let rail = dark ? [0x1A, 0x1D, 0x23] : [0xE4, 0xE5, 0xE8]
        func isRail(_ p: [Int]) -> Bool { zip(p, rail).allSatisfy { abs($0 - $1) <= 2 } }
        let desc = "collapsed row: " + collapsed.map { "\($0.x):\($0.rgb)" }.joined(separator: " ")
        if dark {
            // Unchanged: the band is the rail colour right of the window buttons.
            for s in collapsed where s.x >= 84 && s.x <= 90 {
                XCTAssertTrue(isRail(s.rgb), "x=\(s.x) \(s.rgb) is not the rail colour; \(desc)")
            }
        } else {
            // One colour across the old seam: the rail grey does not appear.
            let railSamples = collapsed.filter { $0.x >= 84 && $0.x <= 200 && isRail($0.rgb) }
            XCTAssertTrue(railSamples.isEmpty,
                          "rail grey at x=\(railSamples.map { $0.x}) (the old seam was at 104); \(desc)")
        }
    }

    /// The colour along the middle of the title-bar row, x = 0...420 every 4 pt,
    /// printed to the log.
    private func row(_ window: XCUIElement, _ context: String) throws -> [(x: Int, rgb: [Int])] {
        let frame = window.frame
        let cg = try XCTUnwrap(window.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cg)
        let scale = Double(cg.width) / Double(frame.width)
        let y = Int(26 * scale)
        var out: [(x: Int, rgb: [Int])] = []
        for x in stride(from: 4, through: 420, by: 4) {
            guard let c = rep.colorAt(x: Int(Double(x) * scale), y: y)?.usingColorSpace(.sRGB) else { continue }
            out.append((x, [Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)]))
        }
        print("TopBandSeam: \(context): row y=26 " + out.map { "\($0.x):\($0.rgb.map { String($0, radix: 16) }.joined(separator: ","))" }.joined(separator: " "))
        return out
    }
}
