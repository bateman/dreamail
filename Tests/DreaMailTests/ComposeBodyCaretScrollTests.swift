import AppKit
import XCTest

/// Return in a compose body that hugs its text must not scroll the clip
/// view for the one runloop turn before SwiftUI grows the editor.
@MainActor
final class ComposeBodyCaretScrollTests: XCTestCase {
    private func makeEditor(height: CGFloat, lines: Int)
        -> (NSScrollView, ComposeCaretSettlingTextView, NSWindow) {
        let scroll = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 400, height: height))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let textView = ComposeCaretSettlingTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: height))
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = .zero
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView?.addSubview(scroll)
        textView.string = Array(repeating: "line", count: lines)
            .joined(separator: "\n")
        textView.setSelectedRange(
            NSRange(location: (textView.string as NSString).length, length: 0))
        return (scroll, textView, window)
    }

    /// Returns once every caret scroll the editor deferred before the call
    /// has run. A fixed `RunLoop.run(until:)` was not enough: when the main
    /// thread stalled past its deadline (busy CI runner), the run loop
    /// returned before draining the main queue, the deferred scroll had not
    /// run yet, and the assertions read a stale origin. Instead, queue a
    /// marker on the main queue with a later deadline than the editor's
    /// settle timer and wait for it: main queue blocks run in deadline
    /// order, so once the marker has run the deferred scroll has run too,
    /// however slow the machine.
    private func waitForDeferredCaretScroll() {
        let marker = expectation(description: "deferred caret scroll ran")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ComposeCaretSettlingTextView.caretScrollSettleDelay * 2
        ) {
            marker.fulfill()
        }
        // The timeout is a safety net against a hang, not the expected wait.
        wait(for: [marker], timeout: 10)
    }

    /// Height of `lines` lines of body text, plus a few points of slack.
    private func fittingHeight(lines: Int) -> CGFloat {
        let line = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 14))
        return CGFloat(lines) * line + 4
    }

    func testReturnDoesNotScrollWhenTheEditorGrowsToFit() {
        let (scroll, textView, window) = makeEditor(
            height: fittingHeight(lines: 5), lines: 5)
        _ = window
        textView.insertNewline(nil)
        // The document is now one line taller than the clip.
        XCTAssertGreaterThan(textView.frame.height, scroll.contentView.bounds.height)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
        // SwiftUI applies the reported height.
        scroll.setFrameSize(NSSize(width: 400, height: fittingHeight(lines: 6)))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
        waitForDeferredCaretScroll()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
    }

    func testReturnFollowsTheCaretWhenTheEditorIsHeightCapped() {
        let (scroll, textView, window) = makeEditor(
            height: fittingHeight(lines: 5), lines: 5)
        _ = window
        textView.insertNewline(nil)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
        // No resize comes: the caret is followed after the settle delay.
        waitForDeferredCaretScroll()
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 1)
    }

    func testScrolledEditorFollowsTheCaretImmediately() {
        let (scroll, textView, window) = makeEditor(
            height: fittingHeight(lines: 5), lines: 12)
        _ = window
        textView.scrollRangeToVisible(textView.selectedRange())
        waitForDeferredCaretScroll()
        let scrolled = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(scrolled, 1)
        textView.insertNewline(nil)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, scrolled + 1)
    }
}
