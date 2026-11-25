import XCTest

final class DatabaseLocationTests: XCTestCase {
    func testUITestsUseASeparateApplicationSupportDirectory() {
        let root = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)
        XCTAssertEqual(
            AppDatabase.storageDirectory(root: root, isUITest: true).lastPathComponent,
            "DreaMailUITests")
        XCTAssertEqual(
            AppDatabase.storageDirectory(root: root, isUITest: false).lastPathComponent,
            "DreaMail")
        XCTAssertEqual(
            AppDatabase.storageDirectory(
                root: root,
                isUITest: false,
                isDeveloperDemo: true
            ).lastPathComponent,
            "DreaMailDemo")
    }
}
