import AppKit
import XCTest

/// A custom accent colour (Settings → Appearance → Accent color) paints
/// the selection: the selected sidebar row's band and the selected
/// thread row are drawn in the stored colour whatever has the focus (their
/// list focused in the key window, another list focused, an inactive
/// window), as Gmail's open conversation and current mailbox are, with
/// glyph and title in white or black as the contrast rule picks
/// (`AccentPalette.onFill`): white on red, black on yellow. With Default
/// the unfocused selection is the system's emphasized colour, not grey.
/// No bar in that ink shows at the leading edge of either list's selected
/// row, in any state (there used to be a 3 pt one on the focused list).
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

    /// The real feature path: pick a swatch in Settings → Appearance, and
    /// the main window's selected sidebar and thread rows are repainted
    /// without a relaunch; Default brings the system highlight back. No `-accentColor`
    /// argument here: the argument domain would hide what Settings writes.
    func testPickingASwatchInSettingsRepaintsTheSidebarLive() throws {
        let (app, main) = launch(accentArgument: nil)
        let inbox = try revealAndFocusInbox(app: app, main: main)
        let strip = { Self.sidebarStrip(row: inbox, window: main) }

        // Start from Default whatever an earlier run left behind.
        try setAccent(app: app, swatch: nil)
        try refocus(inbox, app: app, main: main)
        try assertRow(strip, in: main, is: .systemBlue, "sidebar, Default before the pick")

        // Red swatch (#eb5757): black ink by the rule (white is 3.5:1).
        try setAccent(app: app, swatch: "Red")
        try refocus(inbox, app: app, main: main)
        try assertRow(strip, in: main, is: .accent(Self.redSwatch), "sidebar, after picking Red")
        try assertNoSystemBlue(around: inbox, in: main, "sidebar, after picking Red")
        // The thread list draws the same black ink on its selected row.
        let selected = try focusThreadList(app: app, window: main, accent: Self.redSwatch)
        try assertRow(selected, in: main, is: .accent(Self.redSwatch), "thread list, after picking Red")
        // The sidebar, now unfocused, keeps the picked colour.
        try assertRow(strip, in: main, is: .accent(Self.redSwatch), "sidebar, unfocused after picking Red")

        // Default again: the system highlight is back.
        try setAccent(app: app, swatch: nil)
        try refocus(inbox, app: app, main: main)
        try assertRow(strip, in: main, is: .systemBlue, "sidebar, Default again")
        // Unfocused with Default: the system's emphasized colour, not grey.
        app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
        try assertRow(strip, in: main, is: .systemBlue, "sidebar, Default, focus in the thread list")
    }

    private static let redSwatch = Accent(hex: "#eb5757", rgb: (235, 87, 87), ink: (0, 0, 0))

    // MARK: - Scenario

    private func launch(accentArgument: String?) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchEnvironment["DREAMAIL_DEMO"] = "1"
        app.launchEnvironment["DREAMAIL_UI_TEST"] = "1"
        // The short label list: a ~70-row sidebar makes every query slow.
        app.launchEnvironment["DREAMAIL_DEMO_LABELS"] = "small"
        // The reading pane hidden: moving the selection in the list only
        // highlights (the list stays on screen in a narrow window).
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane",
                                "-readingPaneHidden", "YES"]
        if let accentArgument { app.launchArguments += ["-accentColor", accentArgument] }
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }

        let main = app.windows.matching(
            NSPredicate(format: "NOT (title CONTAINS 'Settings')")).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 10))
        app.activate()
        return (app, main)
    }

    /// Sidebar starts collapsed; → reveals it. Clicking Inbox focuses the
    /// sidebar list: its selection is emphasized.
    private func revealAndFocusInbox(app: XCUIApplication, main: XCUIElement) throws -> XCUIElement {
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        let inbox = main.descendants(matching: .any)
            .matching(identifier: "sidebar.inbox").firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 5))
        inbox.click()
        return inbox
    }

    /// Back to the main window with the sidebar focused.
    private func refocus(_ inbox: XCUIElement, app: XCUIApplication, main: XCUIElement) throws {
        XCTAssertTrue(main.waitForExistence(timeout: 5))
        inbox.click()
    }

    /// Opens Settings → Appearance, clicks the named swatch (nil: Default,
    /// when enabled), and closes Settings again.
    private func setAccent(app: XCUIApplication, swatch: String?) throws {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(
            NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let pane = settings.descendants(matching: .any)
            .matching(identifier: "settings.pane.appearance").firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        pane.click()
        let id = swatch.map { "accentSwatch.\($0)" } ?? "accentColorDefault"
        let control = settings.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5), "\(id) in Settings → Appearance")
        if control.isEnabled { control.click() }
        let value = settings.descendants(matching: .any)
            .matching(identifier: "accentColorValue").firstMatch
        let expected = swatch == nil ? "Default" : Self.redSwatch.hex
        XCTAssertTrue(Self.waitUntil { (value.value as? String ?? value.label) == expected },
                      "the accent row should read \(expected), reads \(value.label)")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(Self.waitUntil { !settings.exists }, "Settings should close with Cmd-W")
    }

    private static func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }

    private func checkSelections(_ accent: Accent) throws {
        let (app, main) = launch(accentArgument: accent.hex)
        let inbox = try revealAndFocusInbox(app: app, main: main)
        let sidebarStrip = { Self.sidebarStrip(row: inbox, window: main) }
        try assertRow(sidebarStrip, in: main, is: .accent(accent), "sidebar, focused")
        try assertNoSystemBlue(around: inbox, in: main, "sidebar, focused")
        // No focus bar at the leading edge, in any state; the other states'
        // edges are also compared with this capture.
        let sidebarEdge = { Self.sidebarEdge(row: inbox, window: main) }
        let sidebarFocusedEdge = try capture(sidebarEdge(), in: main, "sidebar edge, focused").stats.all
        try assertNoBar(sidebarEdge, in: main, accent: accent, "sidebar, focused")

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
        // No system blue at the painted row's leading edge either (label
        // chips further along may be blue).
        let row = selected()
        let threadEdge = { Self.threadEdge(strip: selected()) }
        let threadFocusedEdge = try capture(threadEdge(), in: main, "thread edge, focused").stats.all
        try assertNoSystemBlue(in: CGRect(x: row.minX - 10, y: row.minY - 2,
                                          width: row.width + 10, height: row.height + 4),
                               window: main, "thread list, focused")
        // The sidebar's selection is no longer emphasized: it keeps the
        // accent (and its ink), not the system grey.
        try assertRow(sidebarStrip, in: main, is: .accent(accent), "sidebar, focus in the thread list")
        try assertNoSystemBlue(around: inbox, in: main, "sidebar, focus in the thread list")
        // No bar on the thread list's focused row nor on the unfocused
        // sidebar row, which looks like the focused one: the edge is the same.
        try assertNoBar(threadEdge, in: main, accent: accent, "thread list, focused")
        let sidebarUnfocusedEdge = try assertNoBar(sidebarEdge, in: main, accent: accent,
                                                   same: sidebarFocusedEdge,
                                                   "sidebar, focus in the thread list")

        // Inactive window: the small, centred About panel takes key status.
        let about = app.menuItems["About DreaMail"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.click()
        let panel = app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "the About panel should open")
        // The inactive check only needs the row's background, so the thread
        // strip is cut short of the panel (the wider account rail moves the
        // list towards the centred panel).
        let threadClear: () -> CGRect = {
            let strip = selected()
            let room = panel.frame.minX - strip.minX - 4
            guard room < strip.width else { return strip }
            return CGRect(x: strip.minX, y: strip.minY, width: max(8, room), height: strip.height)
        }
        for (name, strip) in [("sidebar", sidebarStrip()), ("thread", threadClear())] {
            XCTAssertFalse(panel.frame.intersects(strip),
                           "About panel \(panel.frame) covers the \(name) strip \(strip)")
        }
        try assertRow(threadClear, in: main, is: .accent(accent), "thread list, inactive window")
        try assertRow(sidebarStrip, in: main, is: .accent(accent), "sidebar, inactive window")
        // Neither list shows a bar in the inactive window either, and its
        // edges look like the focused ones.
        _ = try assertNoBar(threadEdge, in: main, accent: accent, same: threadFocusedEdge,
                            "thread list, inactive window")
        let sidebarInactiveEdge = try assertNoBar(sidebarEdge, in: main, accent: accent,
                                                  same: sidebarFocusedEdge, "sidebar, inactive window")
        XCTAssertLessThan(Self.differing(sidebarInactiveEdge, sidebarUnfocusedEdge), Self.barPixels,
                          "the unfocused and inactive sidebar edges should look the same")
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

    // MARK: - No focus bar

    /// Pixels in the ink that would make a bar: a 3 pt wide bar is 72 or more
    /// on either row's edge strip; the strip holds none besides antialiasing.
    private static let barPixels = 20

    /// The sidebar row's leading edge: from the window's side of the glyph
    /// to the glyph. Only the band is there: the glyph starts at the row's
    /// content edge and the strip stops 6 pt short of it.
    private static func sidebarEdge(row: XCUIElement, window: XCUIElement) -> CGRect {
        let r = row.frame
        return CGRect(x: r.minX - 40, y: r.minY + 2, width: 34, height: max(1, r.height - 4))
    }

    /// The selected thread row's leading edge, left of its content (inside
    /// the list's own padding, which the row's band covers).
    private static func threadEdge(strip: CGRect) -> CGRect {
        CGRect(x: strip.minX - 40, y: strip.minY, width: 32, height: strip.height)
    }

    /// Pixels that differ clearly between two captures of the same rect.
    private static func differing(_ a: [(Double, Double, Double)],
                                  _ b: [(Double, Double, Double)]) -> Int {
        guard a.count == b.count else { return Int.max }
        return zip(a, b).filter { Pixels.distance($0, $1) > 30 }.count
    }

    /// No bar at the row's leading edge. The band's start is found on the
    /// strip's mid-line (the first pixel in the accent); the 6 pt from there
    /// hold fewer than `barPixels` pixels in the selection ink (a bar is 3 pt
    /// wide and as tall as the row). With `same`, the strip also differs from
    /// that capture in fewer than `barPixels` pixels. Returns the capture.
    @discardableResult
    private func assertNoBar(_ rect: () -> CGRect, in window: XCUIElement,
                             accent: Accent, same: [(Double, Double, Double)]? = nil,
                             _ context: String,
                             file: StaticString = #filePath, line: UInt = #line) throws
        -> [(Double, Double, Double)] {
        var edge: [(Double, Double, Double)] = []
        var inked = 0, changed = 0
        var bandFound = false
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let area = rect()
            let stats = try capture(area, in: window, "\(context) edge", file: file, line: line).stats
            edge = stats.all
            let w = stats.width, h = stats.height
            let scale = Double(w) / max(1, Double(area.width))
            let mid = h / 2
            if w > 0, let start = (0..<w).first(where: {
                Pixels.distance(edge[mid * w + $0], accent.rgb) < 40 }) {
                bandFound = true
                let end = min(w, start + Int((6 * scale).rounded()))
                let rows = Int((2 * scale).rounded())..<max(Int((2 * scale).rounded()) + 1, h - Int((2 * scale).rounded()))
                // Only rows where the band is (the pixel at its start is the
                // accent), so the sidebar and the rail never count as ink.
                inked = rows.reduce(0) { sum, y in
                    guard Pixels.distance(edge[y * w + start], accent.rgb) < 40 else { return sum }
                    return sum + (start..<end).filter {
                        Pixels.distance(edge[y * w + $0], accent.ink) < 40 }.count
                }
            }
            changed = same.map { Self.differing(edge, $0) } ?? 0
            if bandFound, inked < Self.barPixels, changed < Self.barPixels { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        print("AccentColor: \(context): \(inked) ink pixels at the band's start, \(changed) changed pixels")
        XCTAssertTrue(bandFound, "\(context): no accent pixel on the leading edge's mid-line",
                      file: file, line: line)
        XCTAssertLessThan(inked, Self.barPixels, "\(context): a focus bar shows at the leading edge",
                          file: file, line: line)
        XCTAssertLessThan(changed, Self.barPixels,
                          "\(context): the leading edge differs from the focused one",
                          file: file, line: line)
        return edge
    }

    // MARK: - Strips

    /// Glyph and title, inside the band around them.
    private static func sidebarStrip(row: XCUIElement, window: XCUIElement) -> CGRect {
        let r = row.frame
        return CGRect(x: r.minX - 4, y: r.minY, width: r.width + 4, height: r.height)
    }

    /// The leading part of a thread row: unread dot and sender (no label
    /// chips, no star; clear of the centred About panel, which the account
    /// rail's width moves the list towards: hence 44 pt, not 100).
    private static func threadStrip(row: XCUIElement, window: XCUIElement) -> CGRect {
        let r = row.frame
        return CGRect(x: r.minX, y: r.minY + 2, width: min(44, r.width), height: max(1, r.height - 4))
    }

    // MARK: - Pixels

    private enum Expected {
        case accent(Accent)
        /// Not the accent: a grey highlight or the plain background.
        case grey
        /// The system's own (blue) emphasized highlight: the default.
        case systemBlue

        func matches(_ background: (Double, Double, Double)) -> Bool {
            switch self {
            case .accent(let a): return Pixels.distance(background, a.rgb) < 40
            case .grey: return Pixels.ownColour(pixel: background, background: (128, 128, 128)) < 30
            case .systemBlue: return Pixels.isSystemBlue(background)
            }
        }
    }

    /// No system-blue pixel shows around a painted selection (the corners
    /// of a band painted smaller than AppKit's capsule, a seam at an edge).
    private func assertNoSystemBlue(around row: XCUIElement, in window: XCUIElement,
                                    _ context: String, file: StaticString = #filePath,
                                    line: UInt = #line) throws {
        // The sidebar's whole row band: from the window edge across the
        // sidebar, a few points above and below the label.
        let r = row.frame
        let band = CGRect(x: window.frame.minX, y: r.minY - 8,
                          width: r.maxX - window.frame.minX + 30, height: r.height + 16)
        try assertNoSystemBlue(in: band, window: window, context, file: file, line: line)
    }

    private func assertNoSystemBlue(in rect: CGRect, window: XCUIElement, _ context: String,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let (stats, crop) = try capture(rect, in: window, context, file: file, line: line)
        let blue = stats.all.filter(Pixels.isSystemBlue).count
        if blue > 0 {
            let attachment = XCTAttachment(image: NSImage(cgImage: crop, size: .zero))
            attachment.name = "\(context) band"
            XCTContext.runActivity(named: "\(context) system blue") { $0.add(attachment) }
        }
        print("AccentColor: \(context): \(blue) system-blue pixels around the selection")
        XCTAssertEqual(blue, 0, "\(context): system blue shows around the painted selection",
                       file: file, line: line)
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
        // Glyph and title (or sender) stand out from the band …
        XCTAssertGreaterThanOrEqual(stats.foreground, 40, "\(context): nothing drawn on the accent",
                                    file: file, line: line)
        // … and are the rule's ink, blended over the accent at their
        // antialiased edges: not the other of white/black, not a colour.
        let inked = stats.inkFraction(accent: accent)
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
        var all: [(Double, Double, Double)] = []
        /// Size of the cropped image in pixels; `all` is row-major.
        var width = 0
        var height = 0
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
            width = w
            height = h
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
                all.append(p)
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

        /// The system accent blue of an emphasized highlight (#0064E1 and
        /// its neighbours), not a grey, red or yellow, nor their blends.
        static func isSystemBlue(_ p: (Double, Double, Double)) -> Bool {
            p.2 > 150 && p.2 - p.0 > 90 && p.2 - p.1 > 40
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
