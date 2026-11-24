import AppKit
import SwiftUI

/// Benchmark-only draw marker. The workflow injects this behind an actual inbox
/// row or body in both builds. No probe is compiled into the distributed app.
struct MailLatencyProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> Marker { Marker(name: name) }
    func updateNSView(_ view: Marker, context: Context) {}

    final class Marker: NSView {
        private static var clickTime: TimeInterval?
        private static var clickDate: Date?
        /// Clicks in this process: t1, t2, then t1 again for "reopen".
        private static var clickCount = 0
        private static var reported: Set<String> = []
        private static let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            clickTime = ProcessInfo.processInfo.systemUptime
            clickDate = Date()
            clickCount += 1
            return event
        }

        let name: String
        private weak var observedClip: NSClipView?
        private var lastY: CGFloat?
        private var wheelMonitor: Any?
        private var firstWheel: TimeInterval?
        /// When SwiftUI created this marker, i.e. built the body view.
        private let madeAt = ProcessInfo.processInfo.systemUptime
        init(name: String) {
            self.name = name
            super.init(frame: .zero)
            _ = Self.monitor
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard window?.isVisible == true, !visibleRect.isEmpty else { return }
            if name == "inbox" { record(name, since: 0) }
            else if let start = Self.clickTime {
                // The third click re-opens the first conversation.
                record(name == "short" && Self.clickCount >= 3 ? "reopen" : name, since: start)
            }
            if name == "long", observedClip == nil, let clip = enclosingScrollView?.contentView {
                observedClip = clip
                lastY = clip.bounds.minY
                clip.postsBoundsChangedNotifications = true
                // Arm only after the target body draws. Inbox scrolling to
                // locate a fixture must never start a message-scroll sample.
                wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    if let self, self.firstWheel == nil, event.window === self.window {
                        self.firstWheel = ProcessInfo.processInfo.systemUptime
                    }
                    return event
                }
                NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                    name: NSView.boundsDidChangeNotification, object: clip)
            }
        }
        deinit {
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        }
        @objc private func scrolled() {
            guard let y = observedClip?.bounds.minY else { return }
            defer { lastY = y }
            guard let previous = lastY, abs(y - previous) > 0.5, let start = firstWheel else { return }
            record("scroll", since: start)
        }
        private func record(_ key: String, since start: Double) {
            guard Self.reported.insert(key).inserted else { return }
            let seconds = ProcessInfo.processInfo.systemUptime - start
            let token = ProcessInfo.processInfo.environment["MAIL_BENCH_TRIAL"] ?? ""
            let pasteboard = NSPasteboard(name: .init("mishmail.benchmark.\(key)"))
            pasteboard.clearContents()
            pasteboard.setString("\(token) \(seconds)", forType: .string)
            // Stage breakdown for click-driven opens: app intervals that
            // ended after the click (start/end offsets from the click, ms),
            // and when the body view was built.
            guard key != "inbox", key != "scroll", let start = Self.clickTime,
                  let click = Self.clickDate else { return }
            var stages = ["view.made=\(Int((madeAt - start) * 1000))"]
            for sample in PerfMetrics.recentSamples() where sample.at >= click {
                let end = sample.at.timeIntervalSince(click) * 1000
                stages.append("\(sample.event)@\(Int(end - sample.ms))+\(Int(sample.ms))")
            }
            let board = NSPasteboard(name: .init("mishmail.benchmark.stages.\(key)"))
            board.clearContents()
            board.setString("\(token) " + stages.joined(separator: ","), forType: .string)
        }
    }
}
