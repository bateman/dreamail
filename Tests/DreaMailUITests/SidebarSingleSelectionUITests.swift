import AppKit
import XCTest

/// Exactly one sidebar row is drawn selected, always the row of the view on
/// screen, whatever moved the selection: a click on a row under "More", "More"
/// closing and opening, a `g` key sequence, a click back on Inbox. Measured on
/// the window's pixels: on each listed row's mid-line, just inside the sidebar's
/// leading edge, an accent pixel means a drawn band; the selected row's band
/// also spans the row's frame.
final class SidebarSingleSelectionUITests: XCTestCase {

    private static let rows = ["inbox", "starred", "snoozed", "sent", "drafts", "more",
                               "promotions", "social", "updates", "forums", "spam"]

    func testOneBandFollowsTheSelectedView() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-accentColor", "",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane",
                                "-sidebar.more.expanded", "NO"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }
        let main = app.windows.matching(
            NSPredicate(format: "NOT (title CONTAINS 'Settings')")).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 10))
        app.activate()
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])

        func row(_ id: String) -> XCUIElement {
            main.descendants(matching: .any).matching(identifier: "sidebar.\(id)").firstMatch
        }
        XCTAssertTrue(row("inbox").waitForExistence(timeout: 5))
        row("inbox").click()
        expect(only: "inbox", in: main, "Inbox clicked")

        // A row under "More": open it, click Social.
        row("more").click()
        XCTAssertTrue(row("social").waitForExistence(timeout: 5))
        row("social").click()
        expect(only: "social", in: main, "Social clicked under More")

        // "More" closes while Social is selected: Social has no row (DEC-075),
        // so no row is drawn selected. Opening it again shows Social alone.
        row("more").click()
        XCTAssertTrue(waitForAbsence(row("social")))
        expect(only: nil, in: main, "More closed over the selected Social")
        row("more").click()
        XCTAssertTrue(row("social").waitForExistence(timeout: 5))
        expect(only: "social", in: main, "More reopened")

        // Keyboard: `g p` (Promotions) and `g i` (Inbox).
        main.typeKey("g", modifierFlags: [])
        main.typeKey("p", modifierFlags: [])
        expect(only: "promotions", in: main, "g p")
        main.typeKey("g", modifierFlags: [])
        main.typeKey("i", modifierFlags: [])
        expect(only: "inbox", in: main, "g i")

        // Keyboard to a row under More, then More closes: nothing selected.
        main.typeKey("g", modifierFlags: [])
        main.typeKey("p", modifierFlags: [])
        expect(only: "promotions", in: main, "g p again")
        row("more").click()
        XCTAssertTrue(waitForAbsence(row("promotions")))
        expect(only: nil, in: main, "More closed over Promotions")
    }

    // MARK: - Pixels

    private func waitForAbsence(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: 5) == .completed
    }

    /// Retried: the selection redraws a moment after the change.
    private func expect(only id: String?, in window: XCUIElement, _ context: String) {
        var drawn: [String] = []
        var spans: [String: (Double, Double)] = [:]
        let deadline = Date().addingTimeInterval(8)
        repeat {
            (drawn, spans) = bands(in: window)
            if drawn == (id.map { [$0] } ?? []) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        XCTAssertEqual(drawn, id.map { [$0] } ?? [],
                       "\(context): the rows drawn selected must be exactly the view on screen")
        if let id, let span = spans[id] {
            let frame = window.descendants(matching: .any)
                .matching(identifier: "sidebar.\(id)").firstMatch.frame
            XCTAssertEqual(span.0, Double(frame.minY), accuracy: 1.5, "\(context): band top")
            XCTAssertEqual(span.1, Double(frame.maxY), accuracy: 1.5, "\(context): band bottom")
        }
    }

    /// The listed rows that show a band, and each band's vertical extent
    /// (screen points), read at 3 pt inside the sidebar content's leading edge.
    private func bands(in window: XCUIElement) -> ([String], [String: (Double, Double)]) {
        let image = window.screenshot().image
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return ([], [:]) }
        let frame = window.frame
        let scale = Double(cg.width) / Double(frame.width)
        let band = window.descendants(matching: .any)
            .matching(identifier: "sidebarSelectionBand").firstMatch.frame
        let width = cg.width, height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return ([], [:]) }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        func isAccent(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            let i = (y * width + x) * 4
            return max(data[i], data[i + 1], data[i + 2]) - min(data[i], data[i + 1], data[i + 2]) > 60
        }
        let x = Int(((band.minX - frame.minX + 3) * scale).rounded())
        var drawn: [String] = []
        var spans: [String: (Double, Double)] = [:]
        for id in Self.rows {
            let element = window.descendants(matching: .any)
                .matching(identifier: "sidebar.\(id)").firstMatch
            guard element.exists else { continue }
            let f = element.frame
            let midY = Int(((f.midY - frame.minY) * scale).rounded())
            guard isAccent(x, midY) else { continue }
            var top = midY, bottom = midY
            while isAccent(x, top - 1) { top -= 1 }
            while isAccent(x, bottom + 1) { bottom += 1 }
            drawn.append(id)
            spans[id] = (Double(top) / scale + Double(frame.minY), Double(bottom + 1) / scale + Double(frame.minY))
        }
        return (drawn, spans)
    }
}
