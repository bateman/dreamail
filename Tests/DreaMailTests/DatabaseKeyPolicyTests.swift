import XCTest

final class DatabaseKeyPolicyTests: XCTestCase {
    func testDemoBuildAvoidsKeychainBackedDatabaseKey() {
        XCTAssertTrue(AppDatabase.usesFixtureDatabaseKey(
            environment: ["DREAMAIL_DEMO": "1"]
        ))
    }

    func testUITestAvoidsKeychainBackedDatabaseKey() {
        XCTAssertTrue(AppDatabase.usesFixtureDatabaseKey(
            environment: ["DREAMAIL_UI_TEST": "1"]
        ))
    }

    func testRealInboxRequiresKeychainBackedDatabaseKey() {
        XCTAssertFalse(AppDatabase.usesFixtureDatabaseKey(environment: [:]))
        XCTAssertFalse(AppDatabase.usesFixtureDatabaseKey(
            environment: ["DREAMAIL_DEMO": "0", "DREAMAIL_UI_TEST": "0"]
        ))
    }
}
