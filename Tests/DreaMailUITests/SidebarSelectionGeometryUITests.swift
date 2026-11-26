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
/// 3. the capsule's top and bottom edges, and its left end 2 pt below the
///    top (the corner), are the same in the three states too.
/// Each capture waits for the focus bar to be there or gone, so a state
/// that has not redrawn yet is never compared with itself. With the default accent (the first state is then AppKit's capsule, the
/// others the painted one) and a custom one.
final class SidebarSelectionGeometryUITests: XCTestCase {

    private static let minimumInset = 4.0
    private static let tolerance = 0.5

    func testCapsuleGeometryIsStableWithTheDefaultAccent() throws {
        try check(accent: nil)
    }

    func testCapsuleGeometryIsStableWithACustomAccent() throws {
        try check(accent: "#d93025")
    }

    func testCapsuleGeometryIsStableInTheCompactSidebar() throws {
        try check(accent: nil, density: "compact")
    }

    // MARK: - Scenario

    private struct Measure {
        /// Window-relative, in points: the accent run on the row's mid-line.
        let left: Double
        let right: Double
        /// The accent run on a vertical line through the capsule's middle.
        let top: Double
        let bottom: Double
        /// Left end of the run 2 pt below the top: the corner's size.
        let cornerLeft: Double
        let cornerRight: Double
        /// A near-white pixel 3-6 pt inside the left end: the focus bar.
        let bar: Bool
        let sidebarMin: Double
        let sidebarMax: Double
        /// Raw pixels on the mid-line every 4 pt, for reading a failure.
        let samples: String
        var description: String {
            String(format: "capsule x %.1f-%.1f (inset %.1f/%.1f), y %.1f-%.1f (height %.1f), "
                   + "2 pt below the top x %.1f-%.1f, bar %@, sidebar x %.1f-%.1f",
                   left, right, left - sidebarMin, sidebarMax - right, top, bottom, bottom - top,
                   cornerLeft, cornerRight, bar ? "yes" : "no", sidebarMin, sidebarMax)
        }
    }

    private func check(accent: String?, density: String = "comfortable") throws {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", accent ?? "",
                                "-sidebarDensity", density,
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
        print("SidebarSelectionGeometry: macOS \(ProcessInfo.processInfo.operatingSystemVersionString), "
              + "window \(main.frame), outline \(main.outlines.firstMatch.frame), inbox \(inbox.frame)")
        let focused = try measure(inbox: inbox, window: main, bar: true, "focused list")

        let thread = main.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:t3").firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 5))
        thread.click()
        let unfocused = try measure(inbox: inbox, window: main, bar: false,
                                    "focus in the thread list")

        let about = app.menuItems["About DreaMail"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.click()
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 5),
                      "the About panel should open")
        let inactive = try measure(inbox: inbox, window: main, bar: false, "inactive window")

        for (name, m) in [("focused list", focused), ("focus in the thread list", unfocused),
                          ("inactive window", inactive)] {
            XCTAssertGreaterThanOrEqual(m.left - m.sidebarMin, Self.minimumInset,
                                        "\(name): gap to the leading edge, \(m.description)")
            XCTAssertGreaterThanOrEqual(m.sidebarMax - m.right, Self.minimumInset,
                                        "\(name): gap to the trailing edge, \(m.description)")
        }
        let fields: [(String, KeyPath<Measure, Double>)] = [
            ("capsule start", \.left), ("capsule end", \.right),
            ("capsule top", \.top), ("capsule bottom", \.bottom),
            ("corner, left", \.cornerLeft), ("corner, right", \.cornerRight)]
        for (name, m) in [("focus in the thread list", unfocused), ("inactive window", inactive)] {
            for (field, path) in fields {
                XCTAssertEqual(m[keyPath: path], focused[keyPath: path], accuracy: Self.tolerance,
                               "\(name): \(field) moved, \(m.description) vs \(focused.description)")
            }
        }
    }

    // MARK: - Pixels

    /// Captures until the Inbox row shows an accent run and the focus bar is
    /// there (or gone) as the state requires: the selection redraws after a
    /// click, and a capture taken before would compare a state with itself.
    private func measure(inbox: XCUIElement, window: XCUIElement, bar: Bool,
                         _ context: String) throws -> Measure {
        var last = "no accent pixels on the row's mid-line"
        let deadline = Date().addingTimeInterval(8)
        repeat {
            if let m = try capture(inbox: inbox, window: window) {
                if m.bar == bar {
                    print("SidebarSelectionGeometry: \(context): \(m.description)")
                    print("SidebarSelectionGeometry: \(context): mid-line \(m.samples)")
                    return m
                }
                last = "focus bar \(m.bar ? "still there" : "missing"): \(m.description)"
            }
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

        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }
        // Accent: clearly saturated; the sidebar's background and the
        // white ink are not.
        func isAccent(_ x: Int, _ y: Int) -> Bool {
            let p = pixel(x, y)
            return max(p.0, p.1, p.2) - min(p.0, p.1, p.2) > 60
        }
        func isWhite(_ x: Int, _ y: Int) -> Bool {
            let p = pixel(x, y)
            return min(p.0, p.1, p.2) > 200
        }
        let midY = min(height - 1, max(0, Int(((inbox.frame.midY - frame.minY) * scale).rounded())))
        let from = max(0, Int(((sidebar.minX - frame.minX) * scale).rounded()))
        let to = min(width - 1, Int(((sidebar.maxX - frame.minX) * scale).rounded()))
        guard from < to,
              let first = (from...to).first(where: { isAccent($0, midY) }),
              let last = (from...to).last(where: { isAccent($0, midY) })
        else { return nil }

        // Vertical edges, on a line through the capsule's middle.
        let midX = (first + last) / 2
        let rowFrom = max(0, midY - Int(60 * scale)), rowTo = min(height - 1, midY + Int(60 * scale))
        guard let top = (rowFrom...rowTo).first(where: { isAccent(midX, $0) }),
              let bottom = (rowFrom...rowTo).last(where: { isAccent(midX, $0) })
        else { return nil }
        // The corner: the run 2 pt below the top edge.
        let cornerY = min(bottom, top + Int((2 * scale).rounded()))
        guard let cornerFirst = (from...to).first(where: { isAccent($0, cornerY) }),
              let cornerLast = (from...to).last(where: { isAccent($0, cornerY) })
        else { return nil }
        // The focus bar: near-white pixels 3-6 pt inside the left end.
        let bar = (Int((3 * scale).rounded())...Int((6 * scale).rounded())).contains {
            isWhite(first + $0, midY)
        }
        var samples: [String] = []
        let sampleFrom = max(0, Int((((sidebar.minX - frame.minX) - 16) * scale).rounded()))
        let sampleTo = min(width - 1, Int((((sidebar.maxX - frame.minX) + 24) * scale).rounded()))
        for x in stride(from: sampleFrom, through: sampleTo, by: max(1, Int((4 * scale).rounded()))) {
            let p = pixel(x, midY)
            samples.append(String(format: "%.0f:%02x%02x%02x", Double(x) / scale, p.0, p.1, p.2))
        }
        return Measure(left: Double(first) / scale, right: Double(last + 1) / scale,
                       top: Double(top) / scale, bottom: Double(bottom + 1) / scale,
                       cornerLeft: Double(cornerFirst) / scale,
                       cornerRight: Double(cornerLast + 1) / scale, bar: bar,
                       sidebarMin: sidebar.minX - frame.minX, sidebarMax: sidebar.maxX - frame.minX,
                       samples: samples.joined(separator: " "))
    }
}
