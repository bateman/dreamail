import XCTest

/// The sidebar's disclosure state in memory follows "deleted means gone"
/// (DEC-019): a removed account's order and flags do not come back when it
/// is added again in the same run.
final class SidebarDisclosureModelTests: XCTestCase {
    func testForgetDropsARemovedAccountsState() {
        let account = "forget-\(UUID().uuidString)@example.com"
        let other = "keep-\(UUID().uuidString)@example.com"
        defer {
            AccountLifecycle.clearAccountDefaults(accountId: account)
            AccountLifecycle.clearAccountDefaults(accountId: other)
        }
        let model = SidebarDisclosureModel()
        model.setSystemOrder(["sent", "more"], .account(account))
        model.setLabelsMoreOpen(account, true)
        model.setAccountOpen(account, false)
        model.setSystemOrder(["inbox", "more"], .account(other))

        // The removal path clears the defaults; memory still holds them.
        AccountLifecycle.clearAccountDefaults(accountId: account)
        XCTAssertEqual(model.systemOrder(.account(account)), ["sent", "more"])

        model.forget(accountId: account)
        XCTAssertNil(model.systemOrder(.account(account)), "the order is gone")
        XCTAssertFalse(model.labelsMoreOpen(account), "labels More is back to closed")
        XCTAssertTrue(model.accountOpen(account), "the account section is back to open")
        XCTAssertEqual(model.systemOrder(.account(other)), ["inbox", "more"],
                       "other accounts keep theirs")
    }
}
