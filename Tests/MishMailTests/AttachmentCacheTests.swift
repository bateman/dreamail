import XCTest

/// F-04: removing an account deletes its opened-attachment copies, and the
/// cleanup never follows a symbolic link out of the cache.
final class AttachmentCacheTests: XCTestCase {
    private let fm = FileManager.default
    private var base: URL!
    private var root: URL!
    private var outside: URL!
    private var victim: URL { outside.appendingPathComponent("victim.txt") }

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("AttachmentCacheTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent(AttachmentCache.folderName, isDirectory: true)
        outside = base.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("not the cache's".utf8).write(to: victim)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    @discardableResult
    private func cache(account: String, message: String = "m1", row: Int64 = 1,
                       file: String = "report.pdf") throws -> URL {
        let dir = AttachmentCache.messageDirectory(
            root: root, accountId: account, gmailMessageId: message, attachmentRowId: row)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(file)
        try Data("bytes".utf8).write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    func testLayoutMatchesTheOpenPath() {
        let dir = AttachmentCache.messageDirectory(
            root: root, accountId: "a@x.com", gmailMessageId: "18c", attachmentRowId: 42)
        XCTAssertEqual(Array(dir.pathComponents.suffix(4)),
                       [AttachmentCache.folderName, "a@x.com", "18c", "42"])
    }

    func testRemovalDeletesOnlyThatAccountsCopies() throws {
        let a1 = try cache(account: "a@x.com", message: "m1", row: 1)
        let a2 = try cache(account: "a@x.com", message: "m2", row: 2, file: "photo.jpg")
        let b = try cache(account: "b@x.com", message: "m1", row: 3)
        let longer = try cache(account: "a@x.com.au", message: "m1", row: 4)

        XCTAssertTrue(AttachmentCache.removeAccount("a@x.com", root: root))

        XCTAssertFalse(exists(a1))
        XCTAssertFalse(exists(a2))
        XCTAssertFalse(exists(root.appendingPathComponent("a@x.com")))
        XCTAssertTrue(exists(b))
        XCTAssertTrue(exists(longer))
    }

    func testRemovalWithNothingCachedSucceeds() throws {
        XCTAssertTrue(AttachmentCache.removeAccount("a@x.com", root: root),
                      "no cache folder yet")
        try cache(account: "b@x.com")
        XCTAssertTrue(AttachmentCache.removeAccount("a@x.com", root: root))
        XCTAssertTrue(exists(root.appendingPathComponent("b@x.com")))
    }

    /// Links planted inside the account's tree are unlinked; what they point
    /// at stays.
    func testPlantedLinksInsideTheTreeAreNotFollowed() throws {
        let file = try cache(account: "a@x.com")
        let dir = file.deletingLastPathComponent()
        try fm.createSymbolicLink(at: dir.appendingPathComponent("to-dir"),
                                  withDestinationURL: outside)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("to-file"),
                                  withDestinationURL: victim)
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("a@x.com").appendingPathComponent("m9"),
            withDestinationURL: outside)

        XCTAssertTrue(AttachmentCache.removeAccount("a@x.com", root: root))

        XCTAssertFalse(exists(root.appendingPathComponent("a@x.com")))
        XCTAssertTrue(exists(victim))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), ["victim.txt"])
    }

    /// The account folder itself replaced by a link: the link goes, the
    /// directory it names is left whole.
    func testAccountFolderThatIsALinkIsUnlinkedNotFollowed() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("a@x.com")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertTrue(AttachmentCache.removeAccount("a@x.com", root: root))

        XCTAssertFalse(exists(link))
        XCTAssertTrue(exists(victim))
    }

    /// The cache root itself is a link: nothing behind it is ours, so the
    /// removal refuses and deletes nothing.
    func testCacheRootThatIsALinkIsLeftAlone() throws {
        let linkedRoot = base.appendingPathComponent("linked-root", isDirectory: true)
        try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)

        XCTAssertFalse(AttachmentCache.removeAccount("victim.txt", root: linkedRoot))
        XCTAssertTrue(exists(victim))
    }

    func testAccountIdCannotNameAnythingAboveTheCache() throws {
        try cache(account: "b@x.com")
        for id in ["..", ".", "../outside", "/", ""] {
            AttachmentCache.removeAccount(id, root: root)
        }
        XCTAssertTrue(exists(victim))
        XCTAssertTrue(exists(root.appendingPathComponent("b@x.com")))
    }

    // MARK: - Write-side containment

    func testContainmentAcceptsARealTree() throws {
        let file = try cache(account: "a@x.com")
        XCTAssertTrue(AttachmentCache.isContained(file.deletingLastPathComponent(), in: root))
    }

    func testContainmentRejectsALinkAnywhereBelowTheRoot() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("a@x.com"),
                                  withDestinationURL: outside)
        let dir = AttachmentCache.messageDirectory(
            root: root, accountId: "a@x.com", gmailMessageId: "m1", attachmentRowId: 1)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertFalse(AttachmentCache.isContained(dir, in: root))
    }

    func testContainmentRejectsALinkedRootAndPathsOutsideIt() throws {
        let linkedRoot = base.appendingPathComponent("linked-root", isDirectory: true)
        try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
        XCTAssertFalse(AttachmentCache.isContained(linkedRoot, in: linkedRoot))
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertFalse(AttachmentCache.isContained(outside, in: root))
    }
}
