import AppKit
import SwiftUI

/// The selected sidebar row's band for the part of the sidebar the list
/// cannot paint: a row background stops at the list's own inset, so a band
/// drawn only there leaves the margins unpainted. This view sits behind the
/// list, on the sidebar content's own width (x 72-312 on macOS 26: the system
/// insets the sidebar column 8 pt from the rail, outside the Sidebar view, so
/// that strip stays sidebar background), and fills the selected row's height
/// in the same colour as `AccentSelectionBackground`, which still covers
/// AppKit's capsule inside the row. The row comes from the list's own table
/// (`selectedRow`, the mirror of `List(selection:)`), so the selection has one
/// source. Nothing is drawn where the app does not keep the selection colour
/// (before macOS 26).
struct SidebarSelectionBand: NSViewRepresentable {
    let accent: MailAccent

    func makeNSView(context: Context) -> BandView {
        let view = BandView()
        view.accent = accent
        return view
    }

    func updateNSView(_ view: BandView, context: Context) {
        view.accent = accent
        view.refresh()
    }

    final class BandView: NSView {
        var accent = MailAccent.default
        private weak var table: NSTableView?
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // Reported to the UI tests: the view's frame is the sidebar content
        // area the geometry test measures the band against.
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityIdentifier() -> String { "sidebarSelectionBand" }
        override func accessibilityRole() -> NSAccessibility.Role? { .group }
        override var isOpaque: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            refresh()
        }

        override func layout() {
            super.layout()
            refresh()
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        func refresh() {
            if table?.window == nil { attach() }
            needsDisplay = true
        }

        private func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            table = nil
        }

        /// The table of the list in this view's column: the one whose scroll
        /// view's centre lies inside this view.
        private func attach() {
            guard window != nil, let root = window?.contentView else { return }
            let mine = convert(bounds, to: nil)
            var found: NSTableView?
            func walk(_ view: NSView) {
                guard found == nil else { return }
                if let candidate = view as? NSTableView {
                    let host = candidate.enclosingScrollView ?? candidate
                    let frame = host.convert(host.bounds, to: nil)
                    if mine.contains(CGPoint(x: frame.midX, y: frame.midY)) { found = candidate }
                    return
                }
                view.subviews.forEach(walk)
            }
            walk(root)
            guard let table = found else { return }
            detach()
            self.table = table
            let center = NotificationCenter.default
            func watch(_ name: Notification.Name, _ object: AnyObject) {
                observers.append(center.addObserver(forName: name, object: object, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.needsDisplay = true }
                })
            }
            watch(NSTableView.selectionDidChangeNotification, table)
            table.postsFrameChangedNotifications = true
            watch(NSView.frameDidChangeNotification, table)
            if let clip = table.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                watch(NSView.boundsDidChangeNotification, clip)
            }
            watch(NSOutlineView.itemDidExpandNotification, table)
            watch(NSOutlineView.itemDidCollapseNotification, table)
        }

        override func draw(_ dirtyRect: NSRect) {
            guard accent.keepsSelectionColor, let table, table.window != nil else { return }
            let row = table.selectedRow
            guard row >= 0, row < table.numberOfRows else { return }
            let rowRect = convert(table.rect(ofRow: row), from: table)
            var band = NSRect(x: bounds.minX, y: rowRect.minY, width: bounds.width,
                              height: rowRect.height)
            // Only where the list shows: a row scrolled out of view leaves
            // nothing behind the header or the footer.
            if let clip = table.enclosingScrollView?.contentView {
                let visible = convert(clip.bounds, from: clip)
                band = band.intersection(NSRect(x: bounds.minX, y: visible.minY,
                                                width: bounds.width, height: visible.height))
            }
            guard !band.isNull, !band.isEmpty else { return }
            (accent.isCustom ? accent.nsColor(\.fill) : NSColor.selectedContentBackgroundColor).setFill()
            band.fill()
        }
    }
}
