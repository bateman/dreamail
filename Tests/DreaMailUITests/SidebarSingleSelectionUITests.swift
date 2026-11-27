import AppKit
import XCTest

/// Exactly one sidebar row is drawn selected, always the row of the view on
/// screen, whatever moved the selection: a click on a row under "More", "More"
/// closing and opening, a `g` key sequence, a click back on Inbox. Measured on
/// the window's pixels: on each listed row's mid-line, just inside the sidebar's
/// leading edge, an accent pixel means a drawn band; the selected row's band
/// also spans the row's frame.
final class SidebarSingleSelectionUITests: XCTestCase {

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

        // Keyboard: `g p` (Promotions, under More) and `g i` (Inbox).
        main.typeKey("g", modifierFlags: [])
        main.typeKey("p", modifierFlags: [])
        expect(only: "promotions", in: main, "g p")
        main.typeKey("g", modifierFlags: [])
        main.typeKey("i", modifierFlags: [])
        expect(only: "inbox", in: main, "g i")

        // A row of every other kind found on screen: system rows below
        // Inbox, the first label and its first child, a saved view.
        for id in ["important", "allMail", "trash", "scheduled", "reminders"] {
            guard row(id).exists else { continue }
            row(id).click()
            expect(only: id, in: main, "click on \(id)")
        }
        let ids = sidebarRows(in: main).map(\.id)
        let label = ids.filter { $0.hasPrefix("label.") && !$0.hasPrefix("label.menu.") }
        let saved = ids.filter { $0.hasPrefix("saved.") }
        let others: [String] = Array(label.prefix(2)) + Array(saved.prefix(1))
        for id in others {
            row(id).click()
            expect(only: id, in: main, "click on \(id)")
        }

        // Collapse and expand the sidebar: the selection survives.
        main.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        main.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(row("inbox").waitForExistence(timeout: 5))
        row("inbox").click()
        expect(only: "inbox", in: main, "after collapse and expand")

        // Keyboard to a row under More, then More closes: nothing selected.
        main.typeKey("g", modifierFlags: [])
        main.typeKey("p", modifierFlags: [])
        expect(only: "promotions", in: main, "g p again")
        if !row("more").exists { return }
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

    private struct SidebarRow { let id: String; let frame: CGRect }

    /// Every sidebar row on screen, from ONE accessibility snapshot of the
    /// window: the row identifiers only (not the "More" toggle, the add-label
    /// button or a row's own "⋮" menu button).
    private func sidebarRows(in window: XCUIElement) -> [SidebarRow] {
        guard let snapshot = try? window.snapshot() else { return [] }
        var rows: [SidebarRow] = []
        func walk(_ node: XCUIElementSnapshot) {
            let id = node.identifier
            if id.hasPrefix("sidebar."), id != "sidebar.more", id != "sidebar.labels.add",
               !id.hasPrefix("sidebar.label.menu."), node.frame.height > 8 {
                rows.append(SidebarRow(id: String(id.dropFirst("sidebar.".count)), frame: node.frame))
            }
            node.children.forEach { walk($0) }
        }
        walk(snapshot)
        return rows
    }

    /// Retried: the selection redraws a moment after the change. One
    /// screenshot and one snapshot per attempt, whatever the number of rows.
    private func expect(only id: String?, in window: XCUIElement, _ context: String) {
        var runs: [(top: Double, bottom: Double)] = []
        var rows: [SidebarRow] = []
        let deadline = Date().addingTimeInterval(8)
        repeat {
            rows = sidebarRows(in: window)
            runs = selectedRuns(in: window)
            if runs.count == (id == nil ? 0 : 1) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        XCTAssertEqual(runs.count, id == nil ? 0 : 1,
                       "\(context): exactly the view on screen must be drawn selected, runs \(runs), "
                       + "rows \(rows.map { "\($0.id)@\(Int($0.frame.minY))" })")
        guard let id, let run = runs.first, let target = rows.first(where: { $0.id == id }) else {
            if id != nil { XCTFail("\(context): no row \(id ?? "") on screen") }
            return
        }
        // The row's pitch: the distance to its nearest neighbour (the row's own
        // element is the text; the band fills the whole pitch around it).
        let pitch = rows.filter { abs($0.frame.midY - target.frame.midY) > 2 }
            .map { abs($0.frame.midY - target.frame.midY) }.min() ?? 0
        XCTAssertEqual((run.top + run.bottom) / 2, Double(target.frame.midY), accuracy: 2,
                       "\(context): the band is not centred on the row \(id)")
        XCTAssertEqual(run.bottom - run.top, pitch, accuracy: 2,
                       "\(context): the band should fill the row's pitch \(pitch)")
    }

    /// The vertical runs of accent in the sidebar column, read from one
    /// screenshot at four points inside the band area (just inside both edges
    /// and 14 pt in, where AppKit's rounded capsule would show). Short runs
    /// (glyphs, badges) are ignored.
    private func selectedRuns(in window: XCUIElement) -> [(top: Double, bottom: Double)] {
        let image = window.screenshot().image
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let frame = window.frame
        let scale = Double(cg.width) / Double(frame.width)
        let area = window.descendants(matching: .any)
            .matching(identifier: "sidebarSelectionBand").firstMatch.frame
        let width = cg.width, height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        func isAccent(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            let i = (y * width + x) * 4
            return max(data[i], data[i + 1], data[i + 2]) - min(data[i], data[i + 1], data[i + 2]) > 60
        }
        func px(_ x: Double) -> Int { Int(((x - frame.minX) * scale).rounded()) }
        let xs = [px(area.minX + 3), px(area.minX + 14), px(area.maxX - 14), px(area.maxX - 3)]
        let from = max(0, Int(((area.minY - frame.minY) * scale).rounded()))
        let to = min(height - 1, Int(((area.maxY - frame.minY) * scale).rounded()))
        guard from < to else { return [] }
        var runs: [(top: Double, bottom: Double)] = []
        var start: Int?
        for y in from...(to + 1) {
            let on = y <= to && xs.contains { isAccent($0, y) }
            if on, start == nil { start = y }
            if !on, let s = start {
                start = nil
                let top = Double(s) / scale, bottom = Double(y) / scale
                if bottom - top > 8 {
                    runs.append((top + Double(frame.minY), bottom + Double(frame.minY)))
                }
            }
        }
        return runs
    }
}
