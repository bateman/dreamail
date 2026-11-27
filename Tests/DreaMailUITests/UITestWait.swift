import Foundation

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
