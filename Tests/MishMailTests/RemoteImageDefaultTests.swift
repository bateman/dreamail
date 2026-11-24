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

    func testUnknownRawValueFallsBackToDefault() {
        defaults.set("bogus", forKey: RemoteImagePolicy.defaultsKey)
        XCTAssertEqual(RemoteImagePolicy.stored(defaults), RemoteImagePolicy.defaultPolicy)
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
            XCTAssertTrue(RemoteImagePolicy.allows(
                policy: policy, senderEmail: "a@x.com", vipEmails: [],
                messageOptIn: false, threadOptIn: true, inSpam: true), "\(policy)")
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

    /// The card passes the message's own Spam state into the decision.
    func testMessageCardPassesSpamState() throws {
        let text = try Self.repoFile("Sources/MishMail/UI/ThreadDetailView.swift")
        XCTAssertTrue(text.contains("inSpam: RemoteImagePolicy.isSpam(labelIds: message.labelIds)"))
    }

    // MARK: - Pre-render and prefetch

    func testPrerenderNeverAllowsRemoteImages() throws {
        XCTAssertFalse(HTMLBodyPrerenderPolicy.allowRemoteImages)
        // The pre-render (app-only file) keys and paints with the policy
        // constant, never with the user's image policy.
        let prerender = try Self.repoFile("Sources/MishMail/Support/HTMLBodyPrerender.swift")
        XCTAssertTrue(prerender.contains(
            "allowRemoteImages: HTMLBodyPrerenderPolicy.allowRemoteImages"))
        XCTAssertFalse(prerender.contains("allowRemoteImages: true"))
        XCTAssertFalse(prerender.contains("RemoteImagePolicy"))
    }

    func testNeighborPrefetchDoesNotConsultImagePolicy() throws {
        let store = try Self.repoFile("Sources/MishMail/App/MailStore.swift")
        let start = try XCTUnwrap(store.range(of: "private func scheduleNeighborPrefetch("))
        let body = String(store[start.lowerBound...].prefix(4000))
        XCTAssertFalse(body.contains("RemoteImagePolicy"))
        XCTAssertFalse(body.contains("allowRemoteImages: true"))
    }

    // MARK: - CSP pinned for both variants

    func testCSPStringsAreUnchanged() {
        XCTAssertEqual(
            HTMLBodyCSP.metaTag(allowRemoteImages: false),
            "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; "
            + "base-uri 'none'; form-action 'none'; frame-src 'none'; object-src 'none'; "
            + "img-src data: cid:; style-src 'unsafe-inline'\">")
        XCTAssertEqual(
            HTMLBodyCSP.metaTag(allowRemoteImages: true),
            "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; "
            + "base-uri 'none'; form-action 'none'; frame-src 'none'; object-src 'none'; "
            + "img-src data: cid: https:; style-src 'unsafe-inline'\">")
    }

    // MARK: - Settings text

    func testAlwaysFooterSaysSendersCanSeeOpens() {
        let footer = RemoteImagePolicy.always.footer
        XCTAssertTrue(footer.contains("when you opened it"))
        XCTAssertTrue(footer.contains("location"))
        XCTAssertTrue(RemoteImagePolicy.alwaysBlockedNote.contains("Spam"))
    }

    // MARK: - Helpers

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func repoFile(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    static func swiftFiles(under dir: URL) throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
