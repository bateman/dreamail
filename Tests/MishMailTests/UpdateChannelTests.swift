import XCTest

/// The release channel is explicit configuration with no default, and without
/// one the updater is inert: no request, no schedule, no download, no install.
final class UpdateChannelTests: XCTestCase {

    // MARK: - Parsing

    func testParsesOwnerSlashRepository() throws {
        let channel = try XCTUnwrap(UpdateChannel("bateman/mishmail"))
        XCTAssertEqual(channel.owner, "bateman")
        XCTAssertEqual(channel.repository, "mishmail")
        XCTAssertEqual(channel.slug, "bateman/mishmail")
        XCTAssertEqual(channel.latestReleaseURL.absoluteString,
                       "https://api.github.com/repos/bateman/mishmail/releases/latest")
        XCTAssertEqual(UpdateChannel(" some-org/repo.name_2 \n")?.slug, "some-org/repo.name_2")
    }

    func testAnythingButOwnerSlashRepositoryIsNoChannel() {
        for raw: String? in [
            nil, "", "   ",
            // What Info.plist holds if the build setting was never expanded.
            "$(MISHMAIL_UPDATE_CHANNEL)",
            "ronboger", "a/b/c", "/repo", "owner/",
            "https://github.com/owner/repo", "github.com/owner/repo",
            "-owner/repo", "owner-/repo", "ow--ner/repo",
            "owner/.", "owner/..", "own er/repo", "owner/re po",
            "owner/repo?x=1", "owner/repo#x", "ówner/repo",
            String(repeating: "a", count: 40) + "/repo",
            "owner/" + String(repeating: "r", count: 101),
        ] {
            XCTAssertNil(UpdateChannel(raw), "\(raw ?? "nil") must not parse as a channel")
        }
    }

    func testConfiguredChannelComesFromTheInfoDictionaryKey() {
        XCTAssertNil(UpdateChannel.configured(in: nil))
        XCTAssertNil(UpdateChannel.configured(in: [:]))
        XCTAssertNil(UpdateChannel.configured(in: [UpdateChannel.infoKey: ""]))
        XCTAssertNil(UpdateChannel.configured(in: [UpdateChannel.infoKey: 42]))
        XCTAssertEqual(
            UpdateChannel.configured(in: [UpdateChannel.infoKey: "bateman/mishmail"])?.slug,
            "bateman/mishmail")
    }

    // MARK: - Updater without a channel

    @MainActor
    func testExplicitCheckWithoutChannelMakesNoRequestAndSaysDisabled() async {
        let recorder = FetchRecorder()
        let checker = UpdateChecker(channel: nil, fetch: recorder.fetch)
        XCTAssertFalse(checker.isEnabled)

        await checker.check(quietly: false)

        XCTAssertEqual(recorder.count, 0, "no channel must mean no network request")
        XCTAssertNil(checker.available)
        XCTAssertEqual(checker.status, UpdateChecker.disabledStatus)
        XCTAssertEqual(checker.activity, .idle)
    }

    @MainActor
    func testQuietCheckWithoutChannelMakesNoRequest() async {
        let recorder = FetchRecorder()
        let checker = UpdateChecker(channel: nil, fetch: recorder.fetch)
        await checker.check(quietly: true)
        XCTAssertEqual(recorder.count, 0)
        XCTAssertNil(checker.available)
        XCTAssertNil(checker.status)
    }

    @MainActor
    func testStartPeriodicChecksWithoutChannelSchedulesNothing() async {
        let recorder = FetchRecorder()
        let checker = UpdateChecker(channel: nil, fetch: recorder.fetch)

        checker.startPeriodicChecks()
        // Give any task it might have spawned a chance to run.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(checker.isCheckingPeriodically, "no hourly timer without a channel")
        XCTAssertEqual(recorder.count, 0)
    }

    @MainActor
    func testOpenUpdateWithoutChannelNeverStartsAnInstall() {
        let checker = UpdateChecker(channel: nil, fetch: FetchRecorder().fetch)
        // However a release got here, the install path must refuse it.
        checker.available = UpdateChecker.Release(
            version: "99.0.0",
            htmlURL: URL(string: "https://example.invalid/release")!,
            assetURL: URL(string: "https://example.invalid/MishMail-99.0.0.zip")!,
            checksumURL: URL(string: "https://example.invalid/SHA256SUMS")!,
            notes: "")

        checker.openUpdate()

        XCTAssertNil(checker.available)
        XCTAssertEqual(checker.activity, .idle)
        XCTAssertEqual(checker.status, UpdateChecker.disabledStatus)
    }

    // MARK: - Updater with a channel

    @MainActor
    func testConfiguredChannelQueriesExactlyThatRepository() async throws {
        let recorder = FetchRecorder(body: """
            {"tag_name": "v99.0.0", "html_url": "https://github.com/bateman/mishmail/releases/tag/v99.0.0",
             "body": "notes", "assets": [
               {"name": "MishMail-99.0.0.zip", "browser_download_url": "https://example.invalid/MishMail-99.0.0.zip"},
               {"name": "SHA256SUMS", "browser_download_url": "https://example.invalid/SHA256SUMS"}]}
            """)
        let checker = UpdateChecker(channel: UpdateChannel("bateman/mishmail"),
                                    fetch: recorder.fetch)
        XCTAssertTrue(checker.isEnabled)

        await checker.check(quietly: false)

        XCTAssertEqual(recorder.urls.map(\.absoluteString),
                       ["https://api.github.com/repos/bateman/mishmail/releases/latest"])
        let release = try XCTUnwrap(checker.available)
        XCTAssertEqual(release.version, "99.0.0")
        XCTAssertEqual(release.assetURL?.lastPathComponent, "MishMail-99.0.0.zip")
        XCTAssertEqual(release.checksumURL?.lastPathComponent, "SHA256SUMS")
    }
}

/// Stands in for the network: records every request and answers 200 with a
/// fixed body.
private final class FetchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private let body: Data

    init(body: String = "{}") { self.body = Data(body.utf8) }

    var count: Int { lock.withLock { requests.count } }
    var urls: [URL] { lock.withLock { requests.compactMap(\.url) } }

    var fetch: UpdateChecker.Fetch {
        { [self] request in
            lock.withLock { requests.append(request) }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }
}
