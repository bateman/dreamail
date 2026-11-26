import AppKit
import XCTest

/// The sidebar's selected row has one shape in every state: the app paints
/// it itself (a row background, `AccentSelectionBackground`) where AppKit
/// would draw grey, and must match AppKit's own capsule, which it draws
/// with the default accent and a focused list. Measured on the window's
/// pixels, along the Inbox row's horizontal mid-line:
/// 1. the accent run starts and ends at the same x in the three states
///    (focused list, focus in the thread list, inactive window), ±1 pt;
/// 2. a real gap (at least 4 pt) of sidebar background lies between each
///    end of the run and the sidebar's edge, so the capsule never touches
///    the thread list;
/// 3. the glyph's x does not change between states.
/// With the default accent (the first state is then AppKit's capsule, the
/// others the painted one) and a custom one.
final class SidebarSelectionGeometryUITests: XCTestCase {

    private static let minimumInset = 4.0
    private static let tolerance = 1.0

    func testCapsuleGeometryIsStableWithTheDefaultAccent() throws {
        try check(accent: nil)
    }

    func testCapsuleGeometryIsStableWithACustomAccent() throws {
        try check(accent: "#d93025")
    }

    // MARK: - Scenario

    private struct Measure {
        /// Window-relative x, in points.
        let left: Double
        let right: Double
        let glyph: Double
        let sidebarMin: Double
        let sidebarMax: Double
        var description: String {
            String(format: "capsule x %.1f-%.1f, glyph x %.1f, sidebar x %.1f-%.1f",
                   left, right, glyph, sidebarMin, sidebarMax)
        }
    }

    private func check(accent: String?) throws {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", accent ?? "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }

        let main = app.windows.matching(
            NSPredicate(format: "NOT (title CONTAINS 'Settings')")).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 10))
        app.activate()

        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        let inbox = main.descendants(matching: .any)
            .matching(identifier: "sidebar.inbox").firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 5))
        inbox.click()
        let focused = try measure(inbox: inbox, window: main, "focused list")

        let thread = main.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:t3").firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 5))
        thread.click()
        let unfocused = try measure(inbox: inbox, window: main, "focus in the thread list")

        let about = app.menuItems["About DreaMail"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.click()
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 5),
                      "the About panel should open")
        let inactive = try measure(inbox: inbox, window: main, "inactive window")

        for (name, m) in [("focused list", focused), ("focus in the thread list", unfocused),
                          ("inactive window", inactive)] {
            XCTAssertGreaterThanOrEqual(m.left - m.sidebarMin, Self.minimumInset,
                                        "\(name): gap to the leading edge, \(m.description)")
            XCTAssertGreaterThanOrEqual(m.sidebarMax - m.right, Self.minimumInset,
                                        "\(name): gap to the trailing edge, \(m.description)")
        }
        for (name, m) in [("focus in the thread list", unfocused), ("inactive window", inactive)] {
            XCTAssertEqual(m.left, focused.left, accuracy: Self.tolerance,
                           "\(name): capsule start moved, \(m.description) vs \(focused.description)")
            XCTAssertEqual(m.right, focused.right, accuracy: Self.tolerance,
                           "\(name): capsule end moved, \(m.description) vs \(focused.description)")
            XCTAssertEqual(m.glyph, focused.glyph, accuracy: Self.tolerance,
                           "\(name): glyph moved, \(m.description) vs \(focused.description)")
        }
    }

    // MARK: - Pixels

    /// Captures until the Inbox row shows an accent run (the selection
    /// redraws after a click), then measures it.
    private func measure(inbox: XCUIElement, window: XCUIElement, _ context: String) throws -> Measure {
        var last = "no capture"
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let m = try capture(inbox: inbox, window: window) {
                print("SidebarSelectionGeometry: \(context): \(m.description)")
                return m
            }
            last = "no accent pixels on the row's mid-line"
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        XCTFail("\(context): \(last)")
        throw NSError(domain: "SidebarSelectionGeometry", code: 1)
    }

    private func capture(inbox: XCUIElement, window: XCUIElement) throws -> Measure? {
        let frame = window.frame
        let image = window.screenshot().image
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let scale = Double(cg.width) / Double(frame.width)
        let sidebar = window.outlines.firstMatch.frame
        let width = cg.width, height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        let y = min(height - 1, max(0, Int(((inbox.frame.midY - frame.minY) * scale).rounded())))
        let from = max(0, Int(((sidebar.minX - frame.minX) * scale).rounded()))
        let to = min(width - 1, Int(((sidebar.maxX - frame.minX) * scale).rounded()))
        guard from < to else { return nil }
        func pixel(_ x: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }
        // Accent: clearly saturated; the sidebar's background and the
        // white ink are not.
        func isAccent(_ x: Int) -> Bool {
            let p = pixel(x)
            return max(p.0, p.1, p.2) - min(p.0, p.1, p.2) > 60
        }
        guard let first = (from...to).first(where: isAccent),
              let last = (from...to).last(where: isAccent) else { return nil }
        // The glyph: the first near-white pixel inside the run.
        let glyph = ((first + 2)..<max(first + 2, last - 2)).first { x in
            let p = pixel(x)
            return min(p.0, p.1, p.2) > 200
        } ?? first
        return Measure(left: Double(first) / scale, right: Double(last + 1) / scale,
                       glyph: Double(glyph) / scale,
                       sidebarMin: sidebar.minX - frame.minX, sidebarMax: sidebar.maxX - frame.minX)
    }
}
