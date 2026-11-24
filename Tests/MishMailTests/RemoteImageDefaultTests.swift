import XCTest

/// The remote-image default is `.always` (owner decision), defined once.
/// What must not widen with it: Spam, neighbour pre-render, prefetch, CSP.
final class RemoteImageDefaultTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RemoteImageDefaultTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Default

    func testDefaultPolicyIsAlways() {
        XCTAssertEqual(RemoteImagePolicy.defaultPolicy, .always)
    }

    func testUnsetKeyResolvesToAlwaysAndStaysUnset() {
        XCTAssertEqual(RemoteImagePolicy.stored(defaults), .always)
        // An install that never chose keeps following the default: nothing
        // is pinned into its defaults.
        XCTAssertNil(defaults.object(forKey: RemoteImagePolicy.defaultsKey))
        XCTAssertEqual(RemoteImagePolicy.from(raw: nil), .always)
    }

    func testExplicitStoredChoiceIsKept() {
        for policy in RemoteImagePolicy.allCases {
            defaults.set(policy.rawValue, forKey: RemoteImagePolicy.defaultsKey)
            XCTAssertEqual(RemoteImagePolicy.stored(defaults), policy)
            XCTAssertEqual(defaults.string(forKey: RemoteImagePolicy.defaultsKey),
                           policy.rawValue, "stored() must not rewrite a choice")
            XCTAssertEqual(RemoteImagePolicy.from(raw: policy.rawValue), policy)
        }
    }

    func testExplicitAskSurvivesLegacyKeyAndMigration() {
        defaults.set(RemoteImagePolicy.ask.rawValue, forKey: RemoteImagePolicy.defaultsKey)
        defaults.set(true, forKey: RemoteImagePolicy.legacyBoolKey)
        RemoteImagePolicy.migrateIfNeeded(defaults)
        XCTAssertEqual(RemoteImagePolicy.stored(defaults), .ask)
    }

    func testUnknownStoredValueFailsClosedToAsk() {
        defaults.set("bogus", forKey: RemoteImagePolicy.defaultsKey)
        XCTAssertEqual(RemoteImagePolicy.stored(defaults), .ask)
        XCTAssertEqual(RemoteImagePolicy.from(raw: "bogus"), .ask)
        XCTAssertEqual(RemoteImagePolicy.from(raw: ""), .ask)
        XCTAssertEqual(RemoteImagePolicy.from(raw: "Always"), .ask, "case matters")
        // Only a missing value follows the default.
        XCTAssertEqual(RemoteImagePolicy.from(raw: nil), RemoteImagePolicy.defaultPolicy)
    }

    func testLegacyBoolMigrationKeepsItsMeaning() {
        defaults.set(true, forKey: RemoteImagePolicy.legacyBoolKey)
        XCTAssertEqual(RemoteImagePolicy.stored(defaults), .always)
        XCTAssertEqual(defaults.string(forKey: RemoteImagePolicy.defaultsKey), "always")
        XCTAssertNil(defaults.object(forKey: RemoteImagePolicy.legacyBoolKey))

        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: RemoteImagePolicy.legacyBoolKey)
        // A legacy "don't load" becomes an explicit ask, not the new default.
        XCTAssertEqual(RemoteImagePolicy.stored(defaults), .ask)
        XCTAssertEqual(defaults.string(forKey: RemoteImagePolicy.defaultsKey), "ask")
        XCTAssertNil(defaults.object(forKey: RemoteImagePolicy.legacyBoolKey))
    }

    /// One definition: no source file spells its own fallback policy.
    func testDefaultIsDefinedOnce() throws {
        let sources = Self.repoRoot.appendingPathComponent("Sources/MishMail")
        let policyFile = "RemoteImagePolicy.swift"
        var appStorageReads = 0
        for url in try Self.swiftFiles(under: sources) {
            let text = try String(contentsOf: url, encoding: .utf8)
            let name = url.lastPathComponent
            if name != policyFile {
                XCTAssertFalse(text.contains("RemoteImagePolicy(rawValue:"),
                               "\(name) parses the policy itself; use RemoteImagePolicy.from(raw:)")
                XCTAssertFalse(text.contains("RemoteImagePolicy.ask.rawValue"),
                               "\(name) hard-codes an ask fallback")
                XCTAssertFalse(text.contains("RemoteImagePolicy.always.rawValue"),
                               "\(name) hard-codes an always fallback")
            }
            // Every @AppStorage on the key falls back to defaultPolicy.
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated()
            where line.contains("@AppStorage(RemoteImagePolicy.defaultsKey)") {
                appStorageReads += 1
                let decl = lines[i...min(i + 1, lines.count - 1)].joined(separator: " ")
                XCTAssertTrue(decl.contains("RemoteImagePolicy.defaultPolicy.rawValue"),
                              "\(name): @AppStorage fallback must be defaultPolicy")
            }
        }
        XCTAssertGreaterThan(appStorageReads, 0, "scan found no @AppStorage reads")
    }

    // MARK: - Spam

    func testSpamLabelParsing() {
        XCTAssertTrue(RemoteImagePolicy.isSpam(labelIds: "SPAM"))
        XCTAssertTrue(RemoteImagePolicy.isSpam(labelIds: "UNREAD SPAM CATEGORY_UPDATES"))
        XCTAssertFalse(RemoteImagePolicy.isSpam(labelIds: ""))
        XCTAssertFalse(RemoteImagePolicy.isSpam(labelIds: "INBOX UNREAD"))
        XCTAssertFalse(RemoteImagePolicy.isSpam(labelIds: "Label_SPAM SPAMMY"))
    }

    func testSpamBlocksAutoLoadUnderEveryPolicy() {
        let vips: Set<String> = ["friend@x.com"]
        for policy in RemoteImagePolicy.allCases {
            XCTAssertFalse(RemoteImagePolicy.allows(
                policy: policy, senderEmail: "friend@x.com", vipEmails: vips,
                messageOptIn: false, threadOptIn: false,
                senderAuthenticated: true, inSpam: true), "\(policy)")
        }
    }

    func testLoadImagesStillWorksInSpam() {
        for policy in RemoteImagePolicy.allCases {
            XCTAssertTrue(RemoteImagePolicy.allows(
                policy: policy, senderEmail: "a@x.com", vipEmails: [],
                messageOptIn: true, threadOptIn: false, inSpam: true), "\(policy)")
            // The conversation-wide opt-in leaves Spam messages blocked.
            XCTAssertFalse(RemoteImagePolicy.allows(
                policy: policy, senderEmail: "a@x.com", vipEmails: [],
                messageOptIn: false, threadOptIn: true, inSpam: true), "\(policy)")
        }
    }

    /// The card's whole decision, table-driven: policy × sender × VIP auth ×
    /// message labels × thread Spam flag × per-message / per-thread opt-in.
    func testCardDecisionTable() {
        let vips: Set<String> = ["vip@x.com"]
        struct Row {
            let policy: RemoteImagePolicy
            var from = "Someone <a@x.com>"
            var labels = "INBOX"
            var auth: Bool? = nil
            var threadInSpam = false
            var messageOptIn = false
            var threadOptIn = false
            let loads: Bool
        }
        let rows: [Row] = [
            // Policy alone.
            Row(policy: .always, loads: true),
            Row(policy: .ask, loads: false),
            Row(policy: .vip, loads: false),
            Row(policy: .vip, from: "V <vip@x.com>", auth: true, loads: true),
            Row(policy: .vip, from: "V <VIP@X.com>", auth: true, loads: true),
            Row(policy: .vip, from: "V <vip@x.com>", auth: false, loads: false),
            Row(policy: .vip, from: "V <vip@x.com>", auth: nil, loads: false),
            // Spam from the message's labels, or from the thread flag that
            // the optimistic "mark spam" writes before message labels sync.
            Row(policy: .always, labels: "SPAM UNREAD", loads: false),
            Row(policy: .always, threadInSpam: true, loads: false),
            Row(policy: .vip, from: "V <vip@x.com>", labels: "SPAM", auth: true, loads: false),
            Row(policy: .always, labels: "Label_SPAM", loads: true),
            // Opt-ins.
            Row(policy: .ask, messageOptIn: true, loads: true),
            Row(policy: .ask, threadOptIn: true, loads: true),
            Row(policy: .always, labels: "SPAM", messageOptIn: true, loads: true),
            Row(policy: .always, threadInSpam: true, messageOptIn: true, loads: true),
            // "This conversation" does not reach a Spam message.
            Row(policy: .ask, labels: "SPAM", threadOptIn: true, loads: false),
            Row(policy: .always, threadInSpam: true, threadOptIn: true, loads: false),
        ]
        for (i, row) in rows.enumerated() {
            XCTAssertEqual(RemoteImagePolicy.autoLoads(
                policy: row.policy, fromHeader: row.from, messageLabelIds: row.labels,
                senderAuthenticated: row.auth, threadInSpam: row.threadInSpam,
                vipEmails: vips, messageOptIn: row.messageOptIn,
                threadOptIn: row.threadOptIn), row.loads, "row \(i)")
        }
    }

    func testDefaultPolicyLoadsOutsideSpamOnly() {
        XCTAssertTrue(RemoteImagePolicy.allows(
            policy: .defaultPolicy, senderEmail: "a@x.com", vipEmails: [],
            messageOptIn: false, threadOptIn: false, inSpam: false))
        XCTAssertFalse(RemoteImagePolicy.allows(
            policy: .defaultPolicy, senderEmail: "a@x.com", vipEmails: [],
            messageOptIn: false, threadOptIn: false, inSpam: true))
    }

    // MARK: - Pre-render

    func testPrerenderNeverAllowsRemoteImages() {
        XCTAssertFalse(HTMLBodyPrerenderPolicy.allowRemoteImages)
    }

    /// A neighbour is painted only when its open would render the blocked
    /// variant; otherwise the paint could never be claimed. Built from the
    /// same decision as the card, with no opt-ins.
    func testNeighborPrerenderSelection() {
        let vips: Set<String> = ["vip@x.com"]
        struct Row {
            let policy: RemoteImagePolicy
            var from = "a@x.com"
            var labels = "INBOX"
            var auth: Bool? = nil
            var threadInSpam = false
            let paints: Bool
        }
        let rows: [Row] = [
            Row(policy: .always, paints: false),
            Row(policy: .always, labels: "SPAM", paints: true),
            Row(policy: .always, threadInSpam: true, paints: true),
            Row(policy: .ask, paints: true),
            Row(policy: .vip, from: "VIP <vip@x.com>", auth: true, paints: false),
            Row(policy: .vip, from: "VIP <vip@x.com>", auth: nil, paints: true),
            Row(policy: .vip, auth: true, paints: true),
        ]
        for (i, row) in rows.enumerated() {
            let opens = RemoteImagePolicy.autoLoads(
                policy: row.policy, fromHeader: row.from, messageLabelIds: row.labels,
                senderAuthenticated: row.auth, threadInSpam: row.threadInSpam,
                vipEmails: vips, messageOptIn: false, threadOptIn: false)
            XCTAssertEqual(HTMLBodyPrerenderSelection.paintsNeighbor(
                opensWithRemoteImages: opens), row.paints, "row \(i)")
        }
    }

    // MARK: - Settings text

    func testAlwaysFooterStatesWhatTheSenderLearns() {
        let footer = RemoteImagePolicy.always.footer
        XCTAssertTrue(footer.contains("when you opened it"))
        XCTAssertTrue(footer.contains("IP address"))
        XCTAssertTrue(footer.contains("archive or delete"))
        XCTAssertTrue(footer.contains("Ask each time"))
        XCTAssertTrue(RemoteImagePolicy.alwaysBlockedNote.contains("Spam"))
        XCTAssertTrue(RemoteImagePolicy.alwaysBlockedNote.contains("not opened"))
    }

    // MARK: - Helpers

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func swiftFiles(under dir: URL) throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
