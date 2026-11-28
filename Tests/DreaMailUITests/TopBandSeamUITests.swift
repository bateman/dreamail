import XCTest
import AppKit

/// The top band behind the sidebar toggle is one colour. Measured on the
/// background only, along the title-bar row, so it does not depend on where
/// the system toggle is (it sits just right of the window buttons, around
/// x = 95...130, and the old seam ran through it at x = 104).
/// Light, collapsed: the band is the rail's colour along the whole row, as the
/// expanded band is. Dark, collapsed: unchanged, the same colour as the expanded band.
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
        XCTAssertTrue(app.windows.firstMatch.appears(timeout: 10))
        app.activate()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func run(dark: Bool) throws {
        let app = launch(dark: dark)
        XCTAssertTrue(element(app, "threadRow.you@example.com:t3").appears(timeout: 10))
        let window = app.windows.firstMatch
        // Collapsed whatever an earlier suite left.
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "sidebarStrip").appears(timeout: 5), "collapsed")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let collapsed = try row(window, "collapsed")
        // Reading pane open (a thread selected), then a row above the glyphs
        // (y=5) across the window, so a patch of the wrong colour anywhere
        // along the bar fails.
        element(app, "threadRow.you@example.com:t3").click()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let wide = try row(window, "collapsed, reading pane open", y: 5, xMax: Int(window.frame.width) - 16)
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(element(app, "composeButton").appears(timeout: 5), "expanded")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let expanded = try row(window, "expanded")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])

        func rgb(_ rows: [(x: Int, rgb: [Int])], _ xs: [Int]) -> [[Int]] {
            xs.compactMap { x in rows.first { $0.x == x }?.rgb }
        }
        func same(_ a: [Int], _ b: [Int]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 2 } }
        let desc = "collapsed row: " + collapsed.map { "\($0.x):\($0.rgb)" }.joined(separator: " ")
        // Background samples right of the window buttons (to x=100, left of the
        // old seam at 104) and clear of the toggle glyph (x=124...152, right
        // of the seam).
        let left = rgb(collapsed, [84, 88, 92, 96, 100])
        XCTAssertEqual(left.count, 5)
        if dark {
            // Unchanged: the band is the same colour as the rail's band in the
            // expanded layout.
            let reference = rgb(expanded, [84, 88, 92, 96, 100])
            for (a, b) in zip(left, reference) {
                XCTAssertTrue(same(a, b), "dark band \(a) differs from the expanded band \(b); \(desc)")
            }
        } else {
            // Rail colour on both sides of the old seam at x=104 (the toggle),
            // the same as the expanded band.
            let right = rgb(collapsed, [128, 132, 136, 140, 144, 148, 152])
            XCTAssertEqual(right.count, 7)
            let reference = try XCTUnwrap(rgb(expanded, [84, 88, 92, 96, 100]).first)
            // The top edge carries a faint window-material gradient (CI: E4...E9),
            // so compare to the rail colour with a margin that still rejects
            // the content's white (FFFFFF).
            let rail = [0xE4, 0xE5, 0xE8]
            let beyond = wide.filter { $0.x >= 84 }
            XCTAssertGreaterThan(beyond.count, 50)
            for (x, c) in beyond {
                XCTAssertTrue(zip(c, rail).allSatisfy { abs($0 - $1) <= 10 },
                              "top edge at x=\(x): \(c) is not the rail colour \(rail)")
            }
            for c in left + right {
                XCTAssertTrue(same(c, reference), "background \(c) differs from the rail band \(reference); \(desc)")
            }
        }
    }

    /// The colour along a line of the title-bar row (default the middle, y=26), every 4 pt,
    /// printed to the log.
    private func row(_ window: XCUIElement, _ context: String, y yPoints: Int = 26, xMax: Int = 420)
        throws -> [(x: Int, rgb: [Int])] {
        let frame = window.frame
        let cg = try XCTUnwrap(window.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cg)
        let scale = Double(cg.width) / Double(frame.width)
        let y = Int(Double(yPoints) * scale)
        var out: [(x: Int, rgb: [Int])] = []
        for x in stride(from: 4, through: xMax, by: 4) {
            guard let c = rep.colorAt(x: Int(Double(x) * scale), y: y)?.usingColorSpace(.sRGB) else { continue }
            out.append((x, [Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)]))
        }
        print("TopBandSeam: \(context): row y=\(yPoints) " + out.map { "\($0.x):\($0.rgb.map { String($0, radix: 16) }.joined(separator: ","))" }.joined(separator: " "))
        return out
    }
}
