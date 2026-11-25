import AppKit
import SwiftUI

/// Pure placement of a saved window frame on the screens that are connected
/// now. The frame itself is saved by AppKit (frame autosave name); this only
/// decides whether the restored frame is usable.
enum WindowFramePlacement {
    /// `visibleFrames`: each screen's `visibleFrame`, main display first.
    /// Returns `saved` when it already sits inside one screen; otherwise the
    /// frame moved (and, only if it is larger than the screen, shrunk, never
    /// below `minSize`) onto the screen it overlaps most, or the main one.
    static func fit(_ saved: CGRect, in visibleFrames: [CGRect],
                    minSize: CGSize) -> CGRect {
        guard let main = visibleFrames.first else { return saved }
        var target = main
        var bestArea: CGFloat = 0
        for screen in visibleFrames {
            let overlap = screen.intersection(saved)
            if overlap.isNull { continue }
            let area: CGFloat = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                target = screen
            }
        }
        var frame = saved
        let minW: CGFloat = min(minSize.width, target.width)
        let minH: CGFloat = min(minSize.height, target.height)
        frame.size.width = max(min(saved.width, target.width), minW)
        frame.size.height = max(min(saved.height, target.height), minH)
        let maxX: CGFloat = target.maxX - frame.width
        let maxY: CGFloat = target.maxY - frame.height
        frame.origin.x = min(max(frame.minX, target.minX), maxX)
        frame.origin.y = min(max(frame.minY, target.minY), maxY)
        return frame
    }
}

/// Gives the main window a stable frame autosave name (AppKit restores and
/// saves size + position, also after close-and-reopen from the Dock), then
/// makes sure the restored frame is on a connected display.
struct MainWindowFrame: NSViewRepresentable {
    static let autosaveName = "MishMailMainWindow"

    /// UI tests get the default geometry every launch; only the test that
    /// checks restoring opts in with `MISHMAIL_UI_TEST_RESTORE_FRAME=1`.
    static var ignoresSavedFrame: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["MISHMAIL_UI_TEST"] == "1" && env["MISHMAIL_UI_TEST_RESTORE_FRAME"] != "1"
    }

    func makeNSView(context: Context) -> NSView { Anchor() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // TEMP-PROBE (remove before final head)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let w = self?.window else { return }
                let keys = UserDefaults.standard.dictionaryRepresentation()
                    .filter { $0.key.hasPrefix("NSWindow Frame") }
                let pb = NSPasteboard(name: NSPasteboard.Name(
                    "io.github.bateman.mishmail.uitest.breadcrumbs"))
                pb.clearContents()
                pb.setString(
                    "PROBE autosaveName='\(w.frameAutosaveName)' frame=\(w.frame) keys=\(keys)",
                    forType: .string)
            }
            if ProcessInfo.processInfo.environment["MISHMAIL_FRAME_PROBE_ONLY"] == "1" { return }
            guard let window, !MainWindowFrame.ignoresSavedFrame,
                  window.frameAutosaveName.isEmpty else { return }
            // After SwiftUI's first layout, so its default size can't win.
            DispatchQueue.main.async { [weak window] in
                guard let window, window.frameAutosaveName.isEmpty else { return }
                _ = window.setFrameAutosaveName(MainWindowFrame.autosaveName)
                // Full screen / zoomed come back the system's way.
                guard !window.styleMask.contains(.fullScreen), !window.isZoomed else { return }
                let screens = NSScreen.screens.map(\.visibleFrame)
                let fitted = WindowFramePlacement.fit(
                    window.frame, in: screens, minSize: window.contentMinSize)
                if fitted != window.frame { window.setFrame(fitted, display: true) }
            }
        }
    }
}
