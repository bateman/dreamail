import AppKit
import XCTest

/// TEMPORARY probe (removed before review): prints scanlines across the
/// selected sidebar and thread rows in each selection state, so the CI log
/// shows which signals reach a `.listRowBackground` view and whether the
/// system highlight draws over it. Never fails on colours.
final class AccentSelectionProbeUITests: XCTestCase {

    func testProbeSelectionSignals() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
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
        let thread = main.descendants(matching: .any)
            .matching(identifier: "threadRow.you@example.com:t3").firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 5))

        try dump("launch", main, [("inbox", inbox), ("thread", thread)])
        inbox.click()
        settle()
        try dump("sidebar focused", main, [("inbox", inbox), ("thread", thread)])
        thread.click()
        settle()
        try dump("thread list focused", main, [("inbox", inbox), ("thread", thread)])
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        settle()
        let next = main.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'threadRow.'"))
            .allElementsBoundByIndex.map(\.identifier)
        print("PROBE rows: \(next.prefix(6))")
        try dump("after down arrow", main, [("inbox", inbox), ("thread", thread)])

        let about = app.menuItems["About MishMail"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.click()
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 5))
        settle()
        try dump("inactive window", main, [("inbox", inbox), ("thread", thread)])
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(1.0)) }

    private func dump(_ state: String, _ window: XCUIElement,
                      _ rows: [(String, XCUIElement)]) throws {
        let frame = window.frame
        let image = window.screenshot().image
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let scale = CGFloat(cg.width) / frame.width
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: &data, width: cg.width, height: cg.height,
                                          bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        for (name, row) in rows {
            let r = row.frame
            print("PROBE [\(state)] \(name) frame \(r) window \(frame)")
            for dy in [1.0, 3.0, r.height / 2] {
                let y = Int(((r.minY + dy) - frame.minY) * scale)
                guard y >= 0, y < cg.height else { continue }
                var runs: [String] = []
                var start = 0
                var current: (Int, Int, Int)?
                func key(_ x: Int) -> (Int, Int, Int) {
                    let i = (y * cg.width + x) * 4
                    return (Int(data[i]) / 16, Int(data[i + 1]) / 16, Int(data[i + 2]) / 16)
                }
                for x in 0...cg.width {
                    let k = x < cg.width ? key(x) : nil
                    if let c = current, k.map({ $0 != c }) ?? true {
                        if x - start >= Int(3 * scale) {
                            let i = (y * cg.width + start) * 4
                            runs.append(String(format: "%.0f-%.0f:#%02x%02x%02x",
                                               Double(start) / scale, Double(x) / scale,
                                               data[i], data[i + 1], data[i + 2]))
                        }
                        start = x
                    }
                    current = k
                }
                print("PROBE [\(state)] \(name) y+\(Int(dy)): \(runs.joined(separator: " "))")
            }
        }
    }
}
