import AppKit
import XCTest

/// TEMPORARY evidence for #65: does SwiftUI already name and restore the
/// main window's frame (our anchor is disabled here)? Removed before merge.
final class TempFrameProbeUITests: XCTestCase {
    private static func crumbs() -> String {
        NSPasteboard(name: NSPasteboard.Name("io.github.bateman.mishmail.uitest.breadcrumbs"))
            .string(forType: .string) ?? "(none)"
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchEnvironment["MISHMAIL_FRAME_PROBE_ONLY"] = "1"
        app.launch()
        return app
    }

    func testProbeSwiftUIRestore() {
        let first = launch()
        let window = first.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let before = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        corner.withOffset(CGVector(dx: -2, dy: -2))
            .press(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: -42, dy: -32)))
        Thread.sleep(forTimeInterval: 2)
        let after = window.frame
        print("FRAMEPROBE run1 before=\(before) after=\(after)\n\(Self.crumbs())")
        first.terminate()

        let second = launch()
        addTeardownBlock { second.terminate() }
        let reopened = second.windows.firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        print("FRAMEPROBE run2 frame=\(reopened.frame) restored=\(abs(reopened.frame.width - after.width) < 2)\n\(Self.crumbs())")
    }
}
