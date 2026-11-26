import AppKit
import XCTest

/// The sidebar's selected row is one square band in every state: the app
/// paints it itself (a row background, `AccentSelectionBackground`), also
/// where AppKit would draw its own rounded capsule (default accent, focused
/// list), which the band fully covers. Measured on the window's pixels:
/// 1. the accent run on the Inbox row's mid-line spans from the sidebar's
///    leading edge to its trailing edge (±1 pt), in the three states
///    (focused list, focus in the thread list, inactive window);
/// 2. on a line 1 pt below the row's top edge the run has the same extent:
///    the corners are square;
/// 3. no pixel of a different blue sits beside the band, where a system
///    band would show;
/// 4. the icon's and the title's x positions are the same in the three states.
/// With the default accent and a custom one, and in the Compact sidebar.
final class SidebarSelectionGeometryUITests: XCTestCase {

    private static let tolerance = 1.0
    /// Corners and heights: half a point, so a radius of 3 does not pass.
    private static let fine = 0.5
    /// `AccountRailMetrics.width`: the sidebar column starts where the rail ends.
    private static let railWidth = 64.0

    func testBandGeometryIsStableWithTheDefaultAccent() throws {
        try check(accent: nil)
    }

    func testBandGeometryIsStableWithACustomAccent() throws {
        try check(accent: "#d93025")
    }

    func testBandGeometryIsStableInTheCompactSidebar() throws {
        try check(accent: nil, density: "compact")
    }

    // MARK: - Scenario

    private struct Measure {
        /// Window-relative, in points: the accent run on the row's mid-line.
        let left: Double
        let right: Double
        /// The run on a line 1 pt below the row's top edge.
        let topLeft: Double
        let topRight: Double
        /// The run on the band's first pixel row, and its vertical extent.
        let firstLeft: Double
        let firstRight: Double
        let top: Double
        let bottom: Double
        /// Near-white pixels in the band's first 12 pt: a bar.
        let barPixels: Int
        /// Pixels of a different blue inside the band, and where (x, pt).
        let strayBlue: Int
        let strayAt: String
        /// Where the icon and the title start (first white-ink columns).
        let iconX: Double
        let titleX: Double
        let sidebarMin: Double
        let sidebarMax: Double
        /// Raw pixels on the mid-line every 4 pt, for reading a failure.
        let samples: String
        var description: String {
            String(format: "band x %.1f-%.1f (gap %.1f/%.1f), y %.1f-%.1f (height %.1f), first row "
                   + "x %.1f-%.1f, 1 pt below the top x %.1f-%.1f, bar pixels %d, stray blue %d [%@], "
                   + "icon x %.1f, title x %.1f, column x %.1f-%.1f",
                   left, right, left - sidebarMin, sidebarMax - right, top, bottom, bottom - top,
                   firstLeft, firstRight, topLeft, topRight, barPixels, strayBlue, strayAt,
                   iconX, titleX, sidebarMin, sidebarMax)
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
              + "window \(main.frame), outlines \(main.outlines.allElementsBoundByIndex.map(\.frame)), "
              + "scroll views \(main.scrollViews.allElementsBoundByIndex.map(\.frame)), "
              + "scroll bars \(main.scrollBars.allElementsBoundByIndex.map(\.frame)), inbox \(inbox.frame), "
              + "band view \(main.descendants(matching: .any).matching(identifier: "sidebarSelectionBand").allElementsBoundByIndex.map(\.frame)), "
              + "search field \(main.searchFields.allElementsBoundByIndex.map(\.frame)), "
              + "labels header \(main.staticTexts.matching(identifier: "Labels").allElementsBoundByIndex.map(\.frame)), "
              + "add label \(main.descendants(matching: .any).matching(identifier: "sidebar.labels.add").allElementsBoundByIndex.map(\.frame))")
        let starred = main.descendants(matching: .any)
            .matching(identifier: "sidebar.starred").firstMatch
        XCTAssertTrue(starred.waitForExistence(timeout: 5))
        // One row pitch: the band must fill it, with no gap between the areas
        // of two adjacent rows.
        let pitch = Double(starred.frame.minY - inbox.frame.minY)
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
            XCTAssertEqual(m.left, m.sidebarMin, accuracy: Self.tolerance,
                           "\(name): the band should start at the sidebar's leading edge, \(m.description)")
            XCTAssertEqual(m.right, m.sidebarMax, accuracy: Self.tolerance,
                           "\(name): the band should reach the sidebar's trailing edge, \(m.description)")
            for (corner, x, want) in [("first row, left", m.firstLeft, m.left),
                                      ("first row, right", m.firstRight, m.right),
                                      ("1 pt below, left", m.topLeft, m.left),
                                      ("1 pt below, right", m.topRight, m.right)] {
                XCTAssertEqual(x, want, accuracy: Self.fine,
                               "\(name): the top corner is not square (\(corner)), \(m.description)")
            }
            XCTAssertEqual(m.bottom - m.top, pitch, accuracy: 1.0,
                           "\(name): the band should fill the row's pitch \(pitch), \(m.description)")
            XCTAssertEqual(m.barPixels, 0, "\(name): a bar shows at the band's leading edge, \(m.description)")
            XCTAssertEqual(m.strayBlue, 0, "\(name): another blue shows in the band, \(m.description)")
        }
        for (name, m) in [("focus in the thread list", unfocused), ("inactive window", inactive)] {
            XCTAssertEqual(m.top, focused.top, accuracy: Self.fine, "\(name): the band's top moved, \(m.description)")
            XCTAssertEqual(m.bottom, focused.bottom, accuracy: Self.fine,
                           "\(name): the band's bottom moved, \(m.description)")
        }
        // The row content stays where it was before the band reached the edges
        // (CI, macOS 26.7.2: icon 100 / title 124 Compact, 102 / 128 Comfortable).
        let baseline = density == "compact" ? (100.0, 124.0) : (102.0, 128.0)
        for (name, m) in [("focused list", focused), ("focus in the thread list", unfocused),
                          ("inactive window", inactive)] {
            XCTAssertEqual(m.iconX, baseline.0, accuracy: Self.tolerance,
                           "\(name): the icon moved from \(baseline.0), \(m.description)")
            XCTAssertEqual(m.titleX, baseline.1, accuracy: Self.tolerance,
                           "\(name): the title moved from \(baseline.1), \(m.description)")
        }
        for (name, m) in [("focus in the thread list", unfocused), ("inactive window", inactive)] {
            XCTAssertEqual(m.iconX, focused.iconX, accuracy: Self.tolerance,
                           "\(name): the icon moved, \(m.description) vs \(focused.description)")
            XCTAssertEqual(m.titleX, focused.titleX, accuracy: Self.tolerance,
                           "\(name): the title moved, \(m.description) vs \(focused.description)")
        }
    }

    // MARK: - Pixels

    /// Captures until the Inbox row shows an accent run: the selection
    /// redraws after a click, and a capture taken before would compare a state
    /// with itself. The run must also have reached its final extent, so the
    /// capture is retried while the band does not span the sidebar.
    private func measure(inbox: XCUIElement, window: XCUIElement,
                         _ context: String) throws -> Measure {
        var last = "no accent pixels on the row's mid-line"
        var best: Measure?
        let deadline = Date().addingTimeInterval(8)
        repeat {
            if let m = try capture(inbox: inbox, window: window) {
                best = m
                if abs(m.left - m.sidebarMin) <= Self.tolerance, abs(m.right - m.sidebarMax) <= Self.tolerance {
                    break
                }
                last = m.description
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        guard let m = best else {
            XCTFail("\(context): \(last)")
            throw NSError(domain: "SidebarSelectionGeometry", code: 1)
        }
        print("SidebarSelectionGeometry: \(context): \(m.description)")
        print("SidebarSelectionGeometry: \(context): mid-line \(m.samples)")
        return m
    }

    private func capture(inbox: XCUIElement, window: XCUIElement) throws -> Measure? {
        let frame = window.frame
        let image = window.screenshot().image
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let scale = Double(cg.width) / Double(frame.width)
        // The visible column: from the rail's trailing edge to the table's
        // (the thread list starts there). Not the table's own leading edge:
        // the system leaves a margin before it.
        let table = window.outlines.firstMatch.frame
        let sidebar = CGRect(x: frame.minX + Self.railWidth, y: table.minY,
                             width: table.maxX - frame.minX - Self.railWidth, height: table.height)
        let trailing = sidebar.maxX
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
        guard from < to else { return nil }
        // The band's run on a line: from its first accent pixel to the
        // last one before a gap wider than the glyphs and the title leave
        // inside it. A thread-list row selected in the accent starts well
        // beyond the gap and is not part of it.
        let maxGap = Int((12 * scale).rounded())
        func run(_ y: Int) -> (first: Int, last: Int)? {
            guard let first = (from...to).first(where: { isAccent($0, y) }) else { return nil }
            var last = first
            for x in first...to {
                if isAccent(x, y) { last = x } else if x - last > maxGap { break }
            }
            return (first, last)
        }
        guard let mid = run(midY) else { return nil }
        let first = mid.first, last = mid.last

        // Vertical edges, on a line 3 pt inside the band's leading end (clear
        // of the glyph and title).
        let probeX = min(width - 1, first + Int((3 * scale).rounded()))
        let rowFrom = max(0, midY - Int(60 * scale)), rowTo = min(height - 1, midY + Int(60 * scale))
        guard let top = (rowFrom...rowTo).first(where: { isAccent(probeX, $0) }),
              let bottom = (rowFrom...rowTo).last(where: { isAccent(probeX, $0) })
        else { return nil }
        // The corners: the run on the first pixel row and 1 pt below it.
        guard let firstRow = run(top),
              let corner = run(min(bottom, top + Int(scale.rounded()))) else { return nil }
        // A bar: near-white pixels in the band's first 12 pt (the icon starts
        // 28 pt in).
        var bar = 0
        for y in (top + Int(2 * scale))..<max(top + Int(2 * scale), bottom - Int(2 * scale)) {
            for x in first..<min(width, first + Int((12 * scale).rounded())) where isWhite(x, y) { bar += 1 }
        }
        // A different blue inside the band, left of the glyph and right of
        // the count, 2 pt clear of its edges (antialiasing): where AppKit's own
        // band would show.
        let (br, bg, bb) = pixel(probeX, midY)
        func differentBlue(_ x: Int, _ y: Int) -> Bool {
            let p = pixel(x, y)
            let d = (abs(p.0 - br) + abs(p.1 - bg) + abs(p.2 - bb)) / 3
            return p.2 - p.0 > 60 && d > 40
        }
        let margin = Int((2 * scale).rounded())
        let glyphX = Int(((inbox.frame.minX - frame.minX - 4) * scale).rounded())
        let leftZone = (first + margin)..<max(first + margin, glyphX)
        let rightZone = max(first, last - Int((10 * scale).rounded()))..<max(first, last - margin)
        var stray = 0
        var strayColumns = Set<Int>()
        for y in (top + margin)..<max(top + margin, bottom - margin) {
            for x in Array(leftZone) + Array(rightZone) where differentBlue(x, y) {
                stray += 1
                strayColumns.insert(x)
            }
        }
        let strayAt = strayColumns.sorted().prefix(6)
            .map { String(format: "%.1f", Double($0) / scale) }.joined(separator: ",")
        // Where the icon and the title start: the first white-ink columns
        // inside the band, the title after a gap wider than a letter space.
        var inkColumns: [Int] = []
        for x in (first + Int((4 * scale).rounded()))...max(first + 1, last) {
            if ((top + Int(2 * scale))...max(top + Int(2 * scale), bottom - Int(2 * scale)))
                .contains(where: { isWhite(x, $0) }) { inkColumns.append(x) }
        }
        let iconStart = inkColumns.first ?? first
        var titleStart = iconStart
        var previous = iconStart
        for x in inkColumns where x > iconStart {
            if x - previous > Int((4 * scale).rounded()) { titleStart = x; break }
            previous = x
        }
        var samples: [String] = []
        let sampleFrom = max(0, Int((((sidebar.minX - frame.minX) - 16) * scale).rounded()))
        let sampleTo = min(width - 1, Int((((sidebar.maxX - frame.minX) + 24) * scale).rounded()))
        for x in stride(from: sampleFrom, through: sampleTo, by: max(1, Int((4 * scale).rounded()))) {
            let p = pixel(x, midY)
            samples.append(String(format: "%.0f:%02x%02x%02x", Double(x) / scale, p.0, p.1, p.2))
        }
        // The thread list's own selection can continue the run past the
        // column's edge: the band ends there.
        let edgePixel = Double(to)
        return Measure(left: Double(first) / scale, right: min(Double(last + 1), edgePixel) / scale,
                       topLeft: Double(corner.first) / scale,
                       topRight: Double(corner.last + 1) / scale,
                       firstLeft: Double(firstRow.first) / scale, firstRight: Double(firstRow.last + 1) / scale,
                       top: Double(top) / scale, bottom: Double(bottom + 1) / scale, barPixels: bar,
                       strayBlue: stray, strayAt: strayAt,
                       iconX: Double(iconStart) / scale, titleX: Double(titleStart) / scale,
                       sidebarMin: sidebar.minX - frame.minX, sidebarMax: trailing - frame.minX,
                       samples: samples.joined(separator: " "))
    }
}
