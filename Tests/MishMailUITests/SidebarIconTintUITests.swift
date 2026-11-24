import AppKit
import XCTest

/// The selected sidebar row draws its glyph and title in the label colour,
/// never the accent: in the main sidebar with the window active and
/// inactive, and in the Settings sidebar, with the default and a red accent.
///
/// Reads the rendered pixels of the selected row: a screen capture of the
/// strip from the window's leading edge to the row's trailing edge, where
/// the glyph and the title are drawn. The selection capsule's own colour is
/// not judged: only the pixels that stand out from the strip's background
/// (glyph, title), which must be grey.
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

        // The main window is now inactive (Settings is key). Move Settings
        // off the Inbox row if it covers it, then check the row again.
        let strip = Self.strip(row: inbox, window: main)
        if settings.frame.intersects(strip) {
            let shift = strip.maxX + 20 - settings.frame.minX
            let grab = settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                .withOffset(CGVector(dx: 0, dy: 12))
            grab.press(forDuration: 0.2, thenDragTo: grab.withOffset(CGVector(dx: shift, dy: 0)))
            Self.settle()
        }
        XCTAssertFalse(settings.frame.intersects(Self.strip(row: inbox, window: main)),
                       "Settings must not cover the Inbox row: \(settings.frame)")
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
        // Antialiased edges over a tinted capsule may pick up some colour;
        // an accent-tinted glyph is saturated almost everywhere.
        XCTAssertLessThan(stats.saturatedFraction, 0.15,
                          "\(context): \(stats.saturated) of \(stats.foreground) glyph/title pixels are coloured",
                          file: file, line: line)
    }

    /// Foreground pixels: those far from the strip's most common colour.
    /// Saturated: HSV saturation above 0.4 at a value above 0.25.
    private struct PixelStats {
        var foreground = 0
        var saturated = 0
        var saturatedFraction: Double { foreground == 0 ? 0 : Double(saturated) / Double(foreground) }

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

            for i in stride(from: 0, to: data.count, by: 4) {
                let r = Double(data[i]), g = Double(data[i + 1]), b = Double(data[i + 2])
                let distance = (abs(r - bg.0) + abs(g - bg.1) + abs(b - bg.2)) / 3
                guard distance > 40 else { continue }
                foreground += 1
                let hi = max(r, g, b), lo = min(r, g, b)
                let saturation = hi == 0 ? 0 : (hi - lo) / hi
                if saturation > 0.4, hi / 255 > 0.25 { saturated += 1 }
            }
        }
    }
}
