import XCTest

final class BoundedWaitTests: XCTestCase {
    /// An operation that never answers must not hold the caller past the
    /// limit (quit would hang on a silent notification daemon).
    func testOperationThatNeverCompletesReturnsAtTheLimit() async {
        let start = ContinuousClock.now
        await BoundedWait.run(timeout: .milliseconds(200)) { _ in }
        let elapsed = ContinuousClock.now - start
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(150))
        XCTAssertLessThan(elapsed, .seconds(5))
    }

    /// One that answers at once returns without waiting for the limit.
    func testOperationThatCompletesAtOnceDoesNotWaitForTheLimit() async {
        let start = ContinuousClock.now
        await BoundedWait.run(timeout: .seconds(30)) { done in done() }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(10))
    }

    /// A callback arriving from another thread after a short delay wins
    /// over the limit.
    func testOperationCompletingLaterOnAnotherThreadReturns() async {
        let start = ContinuousClock.now
        await BoundedWait.run(timeout: .seconds(30)) { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { done() }
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(10))
    }
}
