import XCTest

// TEMPORARY: runs the loopback limits tests many times in one CI run to show
// the deadline test no longer flakes. Removed before merge.
extension OAuthLoopbackLimitsTests {
    func testStressRepeatTheWholeClass() async throws {
        for _ in 0..<40 {
            try await testSlowClientsAreClosedAtTheConnectionDeadline()
            try await testAClientWhoseSourcePortIsTakenIsNotCountedAsClosedByTheServer()
            try await testAtTheCapTheOldestWaitingConnectionIsEvicted()
            try await testRedirectSucceedsWhenIdleClientsFillTheStandardCap()
            try await testCallbackSucceedsAmidSlowClientsAndClosesThemAll()
            try await testFailedSignInClosesOpenConnections()
            try await testSignInTimeoutClosesOpenConnections()
            OAuthService.loopbackTimeout = .seconds(5 * 60)
            try await testCancellingTheSignInClosesOpenConnections()
        }
    }
}
