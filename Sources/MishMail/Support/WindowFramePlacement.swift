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
        let target = visibleFrames
            .map { ($0, $0.intersection(saved)) }
            .filter { !$0.1.isNull && $0.1.width > 0 && $0.1.height > 0 }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0 ?? main
        var frame = saved
        frame.size.width = max(min(saved.width, target.width), min(minSize.width, target.width))
        frame.size.height = max(min(saved.height, target.height), min(minSize.height, target.height))
        frame.origin.x = min(max(frame.minX, target.minX), target.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, target.minY), target.maxY - frame.height)
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
