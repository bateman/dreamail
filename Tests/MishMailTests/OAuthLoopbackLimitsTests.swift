import XCTest
import Network

/// Bounds on the OAuth loopback catcher (F-09): a local process must not be
/// able to hold connections open or flood the listener during sign-in, and
/// nothing may stay open once the sign-in ends.
///
/// The tests wait on events (server-side closes seen by the client, listener
/// events), never on fixed sleeps. Timeouts below are only upper bounds that
/// fail a test instead of hanging it; the one short duration is the
/// connection deadline under test, which the client merely has to outlast.
final class OAuthLoopbackLimitsTests: XCTestCase {

    /// Generous bound for something that should happen within milliseconds.
    private let wait: TimeInterval = 10

    override func tearDown() {
        OAuthService.loopbackTimeout = .seconds(5 * 60)
        super.tearDown()
    }

    /// Clients that connect and then send nothing, or only part of a request
    /// line, are closed when their deadline runs out instead of being held
    /// open until the sign-in times out.
    func testSlowClientsAreClosedAtTheConnectionDeadline() async throws {
        let events = LoopbackEventRecorder()
        let service = OAuthService()
        let (port, codeTask) = try service.startLoopbackListener(
            expectedState: "slow-\(UUID().uuidString)",
            limits: LoopbackLimits(maxConnections: 16, connectionDeadline: .milliseconds(300)),
            onEvent: events.record)
        defer { codeTask.cancel() }

        let expired = events.expectation("both deadlines expired", count: 2) {
            $0 == .deadlineExpired
        }
        let idle = SlowLocalClient(port: port, partialRequest: nil)
        let partial = SlowLocalClient(port: port, partialRequest: "GET /oauth2/callback?code=sl")
        await fulfillment(of: [idle.closedByServer, partial.closedByServer, expired], timeout: wait)
        // The deadline closes connections, not the sign-in.
        XCTAssertFalse(events.contains(.closedAll))
    }

    /// At the cap, a further connection is closed unread while the admitted
    /// ones stay open; once one of them goes away, its slot is free again
    /// and a real redirect is accepted.
    func testConnectionsBeyondTheCapAreRefused() async throws {
        let state = "cap-\(UUID().uuidString)"
        let events = LoopbackEventRecorder()
        let service = OAuthService()
        let (port, codeTask) = try service.startLoopbackListener(
            expectedState: state,
            limits: LoopbackLimits(maxConnections: 2, connectionDeadline: .seconds(60)),
            onEvent: events.record)
        defer { codeTask.cancel() }

        let full = events.expectation("cap reached") { $0 == .accepted(open: 2) }
        let first = SlowLocalClient(port: port)
        let second = SlowLocalClient(port: port)
        await fulfillment(of: [full], timeout: wait)

        let refused = events.expectation("third refused") { $0 == .refused }
        let third = SlowLocalClient(port: port)
        await fulfillment(of: [third.closedByServer, refused], timeout: wait)
        XCTAssertFalse(events.contains(.deadlineExpired))
        XCTAssertEqual(events.count(where: \.isRelease), 0,
                       "admitted connections must stay open when a later one is refused")

        let freed = events.expectation("slot freed") { $0 == .released(open: 1) }
        first.stop()
        await fulfillment(of: [freed], timeout: wait)

        let code = "cap-code-\(UUID().uuidString)"
        let url = URL(string: "http://127.0.0.1:\(port)/oauth2/callback?code=\(code)&state=\(state)")!
        let (_, resp) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        let received = try await codeTask.value
        XCTAssertEqual(received, code)
        await fulfillment(of: [second.closedByServer], timeout: wait)
    }

    /// A real redirect still completes while slow clients sit on the
    /// listener, and completing the sign-in closes all of them, plus any
    /// connection attempted afterwards.
    func testCallbackSucceedsAmidSlowClientsAndClosesThemAll() async throws {
        let state = "amid-\(UUID().uuidString)"
        let events = LoopbackEventRecorder()
        let service = OAuthService()
        let (port, codeTask) = try service.startLoopbackListener(
            expectedState: state,
            limits: LoopbackLimits(maxConnections: 4, connectionDeadline: .seconds(60)),
            onEvent: events.record)
        defer { codeTask.cancel() }

        let threeOpen = events.expectation("slow clients admitted") { $0 == .accepted(open: 3) }
        let slow = (0..<3).map { index in
            SlowLocalClient(port: port, partialRequest: index == 0 ? nil : "GET /oauth2/callback?co")
        }
        await fulfillment(of: [threeOpen], timeout: wait)

        let closedAll = events.expectation("listener torn down") { $0 == .closedAll }
        let code = "amid-code-\(UUID().uuidString)"
        let url = URL(string: "http://127.0.0.1:\(port)/oauth2/callback?code=\(code)&state=\(state)")!
        let (_, resp) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        let received = try await codeTask.value
        XCTAssertEqual(received, code)

        await fulfillment(of: [closedAll] + slow.map(\.closedByServer), timeout: wait)
        XCTAssertFalse(events.contains(.deadlineExpired), "closed by completion, not by deadline")

        // Nothing is admitted after the sign-in ended.
        let admissions = events.count(where: \.isAdmission)
        let late = SlowLocalClient(port: port)
        await fulfillment(of: [late.closedByServer], timeout: wait)
        XCTAssertEqual(events.count(where: \.isAdmission), admissions)
    }

    /// Google's error redirect (matching state) fails the sign-in and closes
    /// the other connections too.
    func testFailedSignInClosesOpenConnections() async throws {
        let state = "deny-\(UUID().uuidString)"
        let events = LoopbackEventRecorder()
        let service = OAuthService()
        let (port, codeTask) = try service.startLoopbackListener(
            expectedState: state,
            limits: LoopbackLimits(maxConnections: 4, connectionDeadline: .seconds(60)),
            onEvent: events.record)
        defer { codeTask.cancel() }

        let admitted = events.expectation("slow client admitted") { $0 == .accepted(open: 1) }
        let slow = SlowLocalClient(port: port)
        await fulfillment(of: [admitted], timeout: wait)

        let url = URL(string: "http://127.0.0.1:\(port)/oauth2/callback?error=access_denied&state=\(state)")!
        _ = try await URLSession.shared.data(from: url)
        do {
            _ = try await codeTask.value
            XCTFail("expected authorizationDenied")
        } catch OAuthError.authorizationDenied(let reason) {
            XCTAssertEqual(reason, "access_denied")
        }
        await fulfillment(of: [slow.closedByServer], timeout: wait)
    }

    /// The overall sign-in timeout closes connections still open.
    func testSignInTimeoutClosesOpenConnections() async throws {
        OAuthService.loopbackTimeout = .milliseconds(300)
        let events = LoopbackEventRecorder()
        let service = OAuthService()
        let (port, codeTask) = try service.startLoopbackListener(
            expectedState: "timeout-\(UUID().uuidString)",
            limits: LoopbackLimits(maxConnections: 4, connectionDeadline: .seconds(60)),
            onEvent: events.record)

        let closedAll = events.expectation("listener torn down") { $0 == .closedAll }
        let slow = SlowLocalClient(port: port)
        do {
            _ = try await codeTask.value
            XCTFail("expected the sign-in to time out")
        } catch {
            // timedOut, possibly surfaced as cancellation by the task group.
        }
        await fulfillment(of: [closedAll, slow.closedByServer], timeout: wait)
    }

    /// Cancelling the sign-in (the user closes the sheet) closes connections
    /// still open.
    func testCancellingTheSignInClosesOpenConnections() async throws {
        let events = LoopbackEventRecorder()
        let service = OAuthService()
        let (port, codeTask) = try service.startLoopbackListener(
            expectedState: "cancel-\(UUID().uuidString)",
            limits: LoopbackLimits(maxConnections: 4, connectionDeadline: .seconds(60)),
            onEvent: events.record)

        let admitted = events.expectation("slow client admitted") { $0 == .accepted(open: 1) }
        let slow = SlowLocalClient(port: port)
        await fulfillment(of: [admitted], timeout: wait)

        let closedAll = events.expectation("listener torn down") { $0 == .closedAll }
        codeTask.cancel()
        await fulfillment(of: [closedAll, slow.closedByServer], timeout: wait)
    }
}

/// Collects listener events; `expectation` matches events recorded after it
/// is created, so create it before the action that triggers the event.
private final class LoopbackEventRecorder {
    private struct Waiter {
        let matches: (LoopbackListenerEvent) -> Bool
        let expectation: XCTestExpectation
    }

    private let lock = NSLock()
    private var events: [LoopbackListenerEvent] = []
    private var waiters: [Waiter] = []

    func record(_ event: LoopbackListenerEvent) {
        lock.lock()
        events.append(event)
        let matched = waiters.filter { $0.matches(event) }
        lock.unlock()
        matched.forEach { $0.expectation.fulfill() }
    }

    func expectation(_ description: String, count: Int = 1,
                     matching: @escaping (LoopbackListenerEvent) -> Bool) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        expectation.expectedFulfillmentCount = count
        expectation.assertForOverFulfill = false
        lock.lock()
        waiters.append(Waiter(matches: matching, expectation: expectation))
        lock.unlock()
        return expectation
    }

    func contains(_ event: LoopbackListenerEvent) -> Bool {
        count(where: { $0 == event }) > 0
    }

    func count(where predicate: (LoopbackListenerEvent) -> Bool) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.filter(predicate).count
    }
}

private extension LoopbackListenerEvent {
    var isAdmission: Bool {
        if case .accepted = self { return true }
        return false
    }

    var isRelease: Bool {
        if case .released = self { return true }
        return false
    }
}

/// A local client that connects, optionally sends the start of a request
/// line (never its CRLF), and then waits. `closedByServer` is fulfilled when
/// the other side closes or resets the connection, or refuses it.
private final class SlowLocalClient {
    let closedByServer: XCTestExpectation
    private let connection: NWConnection
    private let lock = NSLock()
    private var finished = false

    init(port: UInt16, partialRequest: String? = "GET /oauth2/callback?code=slow") {
        closedByServer = XCTestExpectation(description: "server closed the slow client")
        connection = NWConnection(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let partialRequest {
                    self.connection.send(content: Data(partialRequest.utf8), completion: .idempotent)
                }
                self.receive()
            case .failed, .waiting:
                // Reset, or refused once the listener is gone.
                self.markClosed()
            default:
                break
            }
        }
        connection.start(queue: .global())
    }

    deinit { connection.cancel() }

    /// Closes the connection from the client side; not a server close.
    func stop() {
        lock.lock()
        finished = true
        lock.unlock()
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.markClosed()
            } else {
                self.receive()
            }
        }
    }

    private func markClosed() {
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        if first { closedByServer.fulfill() }
    }
}
