import AppKit
import XCTest

/// The selected sidebar row draws its glyph and title in neutral colours,
/// never the accent: in the main sidebar with the window active and
/// inactive, and in the Settings sidebar, with the default and a red accent.
///
/// Reads the rendered pixels of the selected row: a screen capture of the
/// strip from the window's leading edge to the row's trailing edge, where
/// the glyph and the title are drawn. The selection capsule's own colour is
/// not judged (a focused sidebar draws a solid accent capsule, and the row
/// then draws white on it, as AppKit does): only the pixels that stand out
/// from the strip's background (glyph, title), each of which must be a grey
/// blended with that background. An accent-tinted glyph is not. An
/// unselected row is the control.
final class SidebarIconTintUITests: XCTestCase {

    func testSelectedRowIsMonochromeWithTheDefaultAccent() throws {
        try checkSelectedRows(accent: nil)
    }

    func testSelectedRowIsMonochromeWithARedAccent() throws {
        // NSGlobalDomain's AppleAccentColor, overridden for this process
        // only through the argument domain: 0 is red.
        try checkSelectedRows(accent: "0")
    }

    // MARK: - Scenario

    private func checkSelectedRows(accent: String?) throws {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane"]
        if let accent { app.launchArguments += ["-AppleAccentColor", accent] }
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }

        let main = app.windows.firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 10))
        app.activate()

        // Sidebar starts collapsed; → reveals it. Clicking Inbox gives the
        // sidebar list focus, so its selection draws emphasized.
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        let inbox = app.descendants(matching: .any)
            .matching(identifier: "sidebar.inbox").firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 5))
        inbox.click()
        Self.settle()
        // Control: an unselected row's outline glyph is grey too, so the
        // measure itself does not see colour where there is none.
        let starred = app.descendants(matching: .any)
            .matching(identifier: "sidebar.starred").firstMatch
        XCTAssertTrue(starred.waitForExistence(timeout: 5))
        try Self.assertMonochrome(row: starred, window: main, "main sidebar, unselected row")
        try Self.assertMonochrome(row: inbox, window: main, "main sidebar, active window")

        // Settings: select General, check its row while Settings is key.
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(
            NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let general = settings.descendants(matching: .any)
            .matching(identifier: "settings.pane.general").firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        general.click()
        Self.settle()
        try Self.assertMonochrome(row: general, window: settings, "Settings sidebar")

        // Inactive main window: close Settings (it covers the sidebar), then
        // open the small, centred About panel, which takes key status.
        app.typeKey("w", modifierFlags: .command)
        Self.settle()
        XCTAssertFalse(settings.exists, "Settings should close with Cmd-W")
        // XCUITest opens the app menu on its way to the item.
        let about = app.menuItems["About MishMail"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.click()
        Self.settle()
        let panels = app.windows.allElementsBoundByIndex.filter { $0.frame != main.frame }
        XCTAssertFalse(panels.isEmpty, "the About panel should open")
        let strip = Self.strip(row: inbox, window: main)
        for panel in panels {
            XCTAssertFalse(panel.frame.intersects(strip),
                           "\(panel.identifier) \(panel.frame) covers the Inbox row \(strip)")
        }
        try Self.assertMonochrome(row: inbox, window: main, "main sidebar, inactive window")
    }

    // MARK: - Pixels

    private static func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    /// Screen rect, in points, of the row's leading strip: the window's
    /// leading edge to the row's trailing edge, the row's height.
    private static func strip(row: XCUIElement, window: XCUIElement) -> CGRect {
        let r = row.frame
        let minX = window.frame.minX
        return CGRect(x: minX, y: r.minY, width: max(1, r.maxX - minX), height: r.height)
    }

    private static func assertMonochrome(row: XCUIElement, window: XCUIElement,
                                         _ context: String,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) throws {
        let rect = strip(row: row, window: window)
        let shot = XCUIScreen.main.screenshot()
        let image = shot.image
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                               file: file, line: line)
        // Element frames are in points; the capture is in pixels.
        let screenWidth = NSScreen.main?.frame.width ?? image.size.width
        let scale = CGFloat(cg.width) / screenWidth
        let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                               width: rect.width * scale, height: rect.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let crop = try XCTUnwrap(cg.cropping(to: pixelRect), "\(context): crop \(pixelRect)",
                                 file: file, line: line)

        let attachment = XCTAttachment(image: NSImage(cgImage: crop, size: .zero))
        attachment.name = "\(context) strip"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: context) { $0.add(attachment) }

        let stats = PixelStats(crop)
        // A glyph and a title stand out from the background.
        XCTAssertGreaterThanOrEqual(stats.foreground, 40,
                                    "\(context): no glyph or title found in the strip",
                                    file: file, line: line)
        // A grey glyph's antialiased edges are grey-over-background blends
        // too; an accent-tinted glyph is coloured almost everywhere.
        let detail = "\(context): \(stats.saturated) of \(stats.foreground) glyph/title pixels are coloured; "
            + "strip \(rect), \(stats.summary(scale: scale))"
        print("SidebarIconTint: \(detail)")
        XCTAssertLessThan(stats.saturatedFraction, 0.15, detail, file: file, line: line)
    }

    /// Foreground pixels: those far from the strip's most common colour
    /// (the background). Coloured ("saturated"): a foreground pixel that is
    /// not a grey alpha-blended over the background, within a tolerance.
    /// With channel deviations d = p - mean(p) and e = bg - mean(bg), a blend
    /// a·bg + (1-a)·grey has d = a·e; the residual |d - a·e| at the best
    /// a in 0...1 measures the colour the pixel adds of its own.
    private struct PixelStats {
        var foreground = 0
        var saturated = 0
        var saturatedFraction: Double { foreground == 0 ? 0 : Double(saturated) / Double(foreground) }
        var background = (0.0, 0.0, 0.0)
        var foregroundSum = (0.0, 0.0, 0.0)
        var saturatedSum = (0.0, 0.0, 0.0)
        var foregroundX = (Int.max, Int.min)
        var saturatedX = (Int.max, Int.min)

        /// Where (x in points from the strip's leading edge) and what the
        /// foreground and the coloured pixels are, for the failure message.
        func summary(scale: CGFloat) -> String {
            func rgb(_ c: (Double, Double, Double), _ n: Int) -> String {
                n == 0 ? "-" : String(format: "rgb(%.0f,%.0f,%.0f)",
                                      c.0 / Double(n), c.1 / Double(n), c.2 / Double(n))
            }
            func range(_ r: (Int, Int)) -> String {
                r.0 > r.1 ? "-" : String(format: "x %.0f-%.0f pt", Double(r.0) / scale, Double(r.1) / scale)
            }
            return "background \(rgb(background, 1)), foreground \(rgb(foregroundSum, foreground)) "
                + "\(range(foregroundX)), coloured \(rgb(saturatedSum, saturated)) \(range(saturatedX))"
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

            var histogram: [Int: Int] = [:]
            for i in stride(from: 0, to: data.count, by: 4) {
                let key = (Int(data[i]) >> 3) << 10 | (Int(data[i + 1]) >> 3) << 5 | Int(data[i + 2]) >> 3
                histogram[key, default: 0] += 1
            }
            guard let mode = histogram.max(by: { $0.value < $1.value })?.key else { return }
            let bg = (Double((mode >> 10) & 31) * 8 + 4, Double((mode >> 5) & 31) * 8 + 4,
                      Double(mode & 31) * 8 + 4)

            background = bg
            for i in stride(from: 0, to: data.count, by: 4) {
                let r = Double(data[i]), g = Double(data[i + 1]), b = Double(data[i + 2])
                let distance = (abs(r - bg.0) + abs(g - bg.1) + abs(b - bg.2)) / 3
                guard distance > 40 else { continue }
                let x = (i / 4) % w
                foreground += 1
                foregroundSum = (foregroundSum.0 + r, foregroundSum.1 + g, foregroundSum.2 + b)
                foregroundX = (min(foregroundX.0, x), max(foregroundX.1, x))
                if Self.ownColour(pixel: (r, g, b), background: bg) > 30 {
                    saturated += 1
                    saturatedSum = (saturatedSum.0 + r, saturatedSum.1 + g, saturatedSum.2 + b)
                    saturatedX = (min(saturatedX.0, x), max(saturatedX.1, x))
                }
            }
        }

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
