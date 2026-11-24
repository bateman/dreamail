import AppKit
import XCTest

/// A custom accent colour (Settings → Appearance → Accent color) paints
/// the selection: the selected sidebar row's capsule and the selected
/// thread row are drawn in the stored colour while their list is focused
/// in the key window, with glyph and title in white or black as the
/// contrast rule picks (`AccentPalette.onFill`): white on red, black on
/// yellow. Unfocused and inactive-window selections stay the system grey.
///
/// Reads the rendered pixels of window-only screenshots, like
/// `SidebarIconTintUITests`: each check crops the row's leading strip,
/// takes its most common colour as the background, and judges the pixels
/// that stand out from it (glyph, title, sender) as blends of the
/// background and the expected ink.
final class AccentColorUITests: XCTestCase {

    private struct Accent {
        let hex: String
        let rgb: (Double, Double, Double)
        /// What the rule draws on it.
        let ink: (Double, Double, Double)
    }

    private static let red = Accent(hex: "#d0201a", rgb: (208, 32, 26), ink: (255, 255, 255))
    private static let yellow = Accent(hex: "#ffcc00", rgb: (255, 204, 0), ink: (0, 0, 0))

    func testRedAccentPaintsSelectionsWithWhiteInk() throws {
        try checkSelections(Self.red)
    }

    func testYellowAccentPaintsSelectionsWithBlackInk() throws {
        try checkSelections(Self.yellow)
    }

    // MARK: - Scenario

    private func checkSelections(_ accent: Accent) throws {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        // The reading pane hidden: moving the selection in the list only
        // highlights (the list stays on screen in a narrow window).
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane",
                                "-readingPaneHidden", "YES",
                                "-accentColor", accent.hex]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }

        let main = app.windows.matching(
            NSPredicate(format: "NOT (title CONTAINS 'Settings')")).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 10))
        app.activate()

        // Sidebar starts collapsed; → reveals it. Clicking Inbox focuses
        // the sidebar list: its selection is emphasized.
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        let inbox = main.descendants(matching: .any)
            .matching(identifier: "sidebar.inbox").firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 5))
        inbox.click()
        let sidebarStrip = { Self.sidebarStrip(row: inbox, window: main) }
        try assertRow(sidebarStrip, in: main, is: .accent(accent), "sidebar, focused")

        // An unselected row keeps the sidebar background: the accent is
        // only on the selection.
        let starred = main.descendants(matching: .any)
            .matching(identifier: "sidebar.starred").firstMatch
        XCTAssertTrue(starred.waitForExistence(timeout: 5))
        try assertRow({ Self.sidebarStrip(row: starred, window: main) }, in: main,
                      is: .grey, "sidebar, unselected row")

        // Focus the thread list and select a row in it.
        let selected = try focusThreadList(app: app, window: main, accent: accent)
        try assertRow(selected, in: main, is: .accent(accent), "thread list, focused")
        // The sidebar's selection is no longer emphasized: system grey.
        try assertRow(sidebarStrip, in: main, is: .grey, "sidebar, focus in the thread list")

        // Inactive window: the small, centred About panel takes key status.
        let about = app.menuItems["About MishMail"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.click()
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "the About panel should open")
        for (name, strip) in [("sidebar", sidebarStrip()), ("thread", selected())] {
            XCTAssertFalse(panel.frame.intersects(strip),
                           "About panel \(panel.frame) covers the \(name) strip \(strip)")
        }
        try assertRow(selected, in: main, is: .grey, "thread list, inactive window")
        try assertRow(sidebarStrip, in: main, is: .grey, "sidebar, inactive window")
    }

    /// Gives the thread list keyboard focus with a row selected, without
    /// opening it: Tab from the sidebar (lists are in the key loop by
    /// default), then ↓ to move the selection. Returns the selected row's
    /// strip, found as the one row drawn in the accent.
    private func focusThreadList(app: XCUIApplication, window: XCUIElement,
                                 accent: Accent) throws -> () -> CGRect {
        let rows = window.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'threadRow.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        var seen: [String] = []
        for attempt in 0..<4 {
            app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
            if attempt == 0 { app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: []) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            for row in rows.allElementsBoundByIndex.prefix(8) {
                let frame = row.frame
                guard !frame.isEmpty, window.frame.contains(frame) else { continue }
                let id = row.identifier
                let strip = { Self.threadStrip(row: window.descendants(matching: .any)
                    .matching(identifier: id).firstMatch, window: window) }
                let stats = try capture(strip(), in: window, "probe \(id)").stats
                seen.append("tab \(attempt + 1) \(id): \(stats.summary)")
                if Pixels.distance(stats.background, accent.rgb) < 40 { return strip }
            }
        }
        XCTFail("no thread row drew the accent after focusing the list:\n" + seen.joined(separator: "\n"))
        throw NotReached()
    }

    private struct NotReached: Error {}

    // MARK: - Strips

    /// Glyph and title, inside the capsule around them.
    private static func sidebarStrip(row: XCUIElement, window: XCUIElement) -> CGRect {
        let r = row.frame
        return CGRect(x: r.minX - 4, y: r.minY, width: r.width + 4, height: r.height)
    }

    /// The leading part of a thread row: unread dot and sender (no label
    /// chips, no star; clear of the centred About panel).
    private static func threadStrip(row: XCUIElement, window: XCUIElement) -> CGRect {
        let r = row.frame
        return CGRect(x: r.minX, y: r.minY + 2, width: min(100, r.width), height: max(1, r.height - 4))
    }

    // MARK: - Pixels

    private enum Expected {
        case accent(Accent)
        /// Not the accent: a grey highlight or the plain background.
        case grey

        func matches(_ background: (Double, Double, Double)) -> Bool {
            switch self {
            case .accent(let a): return Pixels.distance(background, a.rgb) < 40
            case .grey: return Pixels.ownColour(pixel: background, background: (128, 128, 128)) < 30
            }
        }
    }

    /// Captures the strip until its background is as expected (the
    /// selection redraws after a click or a key), then checks it and, on
    /// the accent, the ink of the pixels drawn on it.
    private func assertRow(_ strip: () -> CGRect, in window: XCUIElement, is expected: Expected,
                           _ context: String, file: StaticString = #filePath,
                           line: UInt = #line) throws {
        var shot: (stats: Pixels, crop: CGImage)?
        let deadline = Date().addingTimeInterval(5)
        repeat {
            shot = try capture(strip(), in: window, context, file: file, line: line)
            if let shot, expected.matches(shot.stats.background) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        let (stats, crop) = try XCTUnwrap(shot, file: file, line: line)

        // Kept in the result bundle when the test fails (default lifetime).
        let attachment = XCTAttachment(image: NSImage(cgImage: crop, size: .zero))
        attachment.name = "\(context) strip"
        XCTContext.runActivity(named: context) { $0.add(attachment) }
        print("AccentColor: \(context): \(stats.summary)")

        XCTAssertTrue(expected.matches(stats.background),
                      "\(context): background should be \(expected), \(stats.summary)",
                      file: file, line: line)
        guard case .accent(let accent) = expected else { return }
        // Glyph and title (or sender) stand out from the capsule …
        XCTAssertGreaterThanOrEqual(stats.foreground, 40, "\(context): nothing drawn on the accent",
                                    file: file, line: line)
        // … and are the rule's ink, blended over the accent at their
        // antialiased edges: not the other of white/black, not a colour.
        let inked = stats.inkFraction(ink: accent.ink)
        XCTAssertGreaterThan(inked, 0.85,
                             "\(context): \(Int(inked * 100))% of the drawn pixels are the expected ink; \(stats.summary)",
                             file: file, line: line)
    }

    private func capture(_ rect: CGRect, in window: XCUIElement, _ context: String,
                         file: StaticString = #filePath, line: UInt = #line) throws
        -> (stats: Pixels, crop: CGImage) {
        let frame = window.frame
        let image = window.screenshot().image
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                               file: file, line: line)
        // Element frames are in points; the capture is in pixels.
        let scale = CGFloat(cg.width) / frame.width
        let local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let pixelRect = CGRect(x: local.minX * scale, y: local.minY * scale,
                               width: local.width * scale, height: local.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let crop = try XCTUnwrap(cg.cropping(to: pixelRect), "\(context): crop \(pixelRect)",
                                 file: file, line: line)
        return (Pixels(crop), crop)
    }

    /// The strip's background (most common colour) and the pixels that
    /// stand out from it.
    private struct Pixels {
        var background = (0.0, 0.0, 0.0)
        var drawn: [(Double, Double, Double)] = []
        var foreground: Int { drawn.count }

        var summary: String {
            let n = Double(max(1, drawn.count))
            let sum = drawn.reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2) }
            return String(format: "background rgb(%.0f,%.0f,%.0f), %d drawn pixels, mean rgb(%.0f,%.0f,%.0f)",
                          background.0, background.1, background.2, drawn.count,
                          sum.0 / n, sum.1 / n, sum.2 / n)
        }

        init(_ image: CGImage) {
            let w = image.width, h = image.height
            var data = [UInt8](repeating: 0, count: w * h * 4)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            var histogram: [Int: (Int, Double, Double, Double)] = [:]
            for i in stride(from: 0, to: data.count, by: 4) {
                let key = (Int(data[i]) >> 3) << 10 | (Int(data[i + 1]) >> 3) << 5 | Int(data[i + 2]) >> 3
                let e = histogram[key] ?? (0, 0, 0, 0)
                histogram[key] = (e.0 + 1, e.1 + Double(data[i]), e.2 + Double(data[i + 1]),
                                  e.3 + Double(data[i + 2]))
            }
            guard let mode = histogram.values.max(by: { $0.0 < $1.0 }) else { return }
            let n = Double(mode.0)
            let bg = (mode.1 / n, mode.2 / n, mode.3 / n)
            background = bg
            for i in stride(from: 0, to: data.count, by: 4) {
                let p = (Double(data[i]), Double(data[i + 1]), Double(data[i + 2]))
                if Pixels.distance(p, bg) > 40 { drawn.append(p) }
            }
        }

        /// Share of the drawn pixels that are a blend of the background and
        /// `ink` (the residual from the closest blend is small).
        func inkFraction(ink: (Double, Double, Double)) -> Double {
            guard !drawn.isEmpty else { return 0 }
            let bg = background
            let d = (ink.0 - bg.0, ink.1 - bg.1, ink.2 - bg.2)
            let dd = d.0 * d.0 + d.1 * d.1 + d.2 * d.2
            let good = drawn.filter { p in
                let v = (p.0 - bg.0, p.1 - bg.1, p.2 - bg.2)
                let t = dd < 1 ? 0 : min(1, max(0, (v.0 * d.0 + v.1 * d.1 + v.2 * d.2) / dd))
                let r = (v.0 - t * d.0, v.1 - t * d.1, v.2 - t * d.2)
                return (r.0 * r.0 + r.1 * r.1 + r.2 * r.2).squareRoot() < 45
            }
            return Double(good.count) / Double(drawn.count)
        }

        /// Mean absolute channel difference.
        static func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
            (abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)) / 3
        }

        /// How far a pixel is from a grey alpha-blended over `background`
        /// (see `SidebarIconTintUITests`): 0 for greys.
        static func ownColour(pixel p: (Double, Double, Double),
                              background bg: (Double, Double, Double)) -> Double {
            let pm = (p.0 + p.1 + p.2) / 3, bm = (bg.0 + bg.1 + bg.2) / 3
            let d = (p.0 - pm, p.1 - pm, p.2 - pm)
            let e = (bg.0 - bm, bg.1 - bm, bg.2 - bm)
            let ee = e.0 * e.0 + e.1 * e.1 + e.2 * e.2
            let a = ee < 1 ? 0 : min(1, max(0, (d.0 * e.0 + d.1 * e.1 + d.2 * e.2) / ee))
            let r = (d.0 - a * e.0, d.1 - a * e.1, d.2 - a * e.2)
            return (r.0 * r.0 + r.1 * r.1 + r.2 * r.2).squareRoot()
        }
    }
}
