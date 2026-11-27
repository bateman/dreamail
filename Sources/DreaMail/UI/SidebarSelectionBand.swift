import AppKit
import SwiftUI

/// Keeps AppKit's own selection highlight off the sidebar list where the app
/// paints the selected row itself, so the one painter is the row background
/// (`AccentSelectionBackground`, driven by `MailStore.selectedView`) and no
/// stale `selectedRow` of the list's table can show a second selected row.
/// The view draws nothing. It sits behind the list on the sidebar content's
/// width (the UI tests measure the band against its frame, x 72-312 on macOS
/// 26) and finds the list's own table, the one whose scroll view's centre lies
/// inside it, to set `selectionHighlightStyle`. Where the app does not keep the
/// selection colour (before macOS 26) the table's own style is put back.
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

        private var systemStyle: NSTableView.SelectionHighlightStyle?

        func refresh() {
            if table?.window == nil { attach() }
            apply()
        }

        /// No AppKit highlight on any row while the app paints the selection.
        private func apply() {
            guard let table else { return }
            if accent.keepsSelectionColor {
                if table.selectionHighlightStyle != .none {
                    systemStyle = table.selectionHighlightStyle
                    table.selectionHighlightStyle = .none
                }
            } else if let style = systemStyle {
                table.selectionHighlightStyle = style
                systemStyle = nil
            }
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
                    MainActor.assumeIsolated { self?.apply() }
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
    }
}
