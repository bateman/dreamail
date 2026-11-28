import XCTest

/// Polls a condition on the main run loop; shared by the UI tests that wait
/// for an accessibility label to change.
enum UITestWait {
    static func until(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}

extension XCUIElement {
    /// `waitForExistence(timeout:)` without its first-poll delay: XCTest
    /// checks about a second after the call even when the element is already
    /// there (686 such waits cost about 700 s of a CI run). Same result and
    /// same timeout; an element already on screen returns at once.
    /// Not for "must be gone" checks (`XCTAssertFalse`): there the delay
    /// gives a closing element its time to go, so those keep
    /// `waitForExistence`.
    @discardableResult
    func appears(timeout: TimeInterval) -> Bool {
        exists || waitForExistence(timeout: timeout)
    }
}
