import XCTest

/// The release channel is explicit configuration with no default, and without
/// one — or on an ad-hoc signed copy, even with one — the updater is inert:
/// no request, no schedule, no download, no install.
final class UpdateChannelTests: XCTestCase {

    // MARK: - Parsing

    func testParsesOwnerSlashRepository() throws {
        let channel = try XCTUnwrap(UpdateChannel("bateman/dreamail"))
        XCTAssertEqual(channel.owner, "bateman")
        XCTAssertEqual(channel.repository, "dreamail")
        XCTAssertEqual(channel.slug, "bateman/dreamail")
        XCTAssertEqual(channel.latestReleaseURL.absoluteString,
                       "https://api.github.com/repos/bateman/dreamail/releases/latest")
        XCTAssertEqual(UpdateChannel(" some-org/repo.name_2 \n")?.slug, "some-org/repo.name_2")
        // Same rule as the script's valid_repo: character sets only.
        XCTAssertEqual(UpdateChannel("a--b/-")?.slug, "a--b/-")
    }

    func testAnythingButOwnerSlashRepositoryIsNoChannel() {
        for raw: String? in [
            nil, "", "   ",
            // What Info.plist holds if the build setting was never expanded.
            "$(DREAMAIL_UPDATE_CHANNEL)",
            "ronboger", "a/b/c", "/repo", "owner/",
            "https://github.com/owner/repo", "github.com/owner/repo",
            "owner/.", "owner/..", "own er/repo", "owner/re po",
            "own.er/repo", "own_er/repo", "owner/repo?x=1", "owner/repo#x",
            "ówner/repo", "owner/repó", "owner\\x/repo",
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
            UpdateChannel.configured(in: [UpdateChannel.infoKey: "bateman/dreamail"])?.slug,
            "bateman/dreamail")
    }

    // MARK: - Updater without a channel

    @MainActor
    func testExplicitCheckWithoutChannelMakesNoRequestAndSaysDisabled() async {
        let recorder = FetchRecorder()
        let checker = UpdateChecker(channel: nil, runningTeamID: "ABCDE12345",
                                    fetch: recorder.fetch)
        XCTAssertFalse(checker.isEnabled)

        await checker.check(quietly: false)

        XCTAssertEqual(recorder.count, 0, "no channel must mean no network request")
        XCTAssertNil(checker.available)
        XCTAssertEqual(checker.status, UpdateChecker.noChannelStatus)
        XCTAssertEqual(checker.activity, .idle)
    }

    @MainActor
    func testQuietCheckWithoutChannelMakesNoRequest() async {
        let recorder = FetchRecorder()
        let checker = UpdateChecker(channel: nil, runningTeamID: "ABCDE12345",
                                    fetch: recorder.fetch)
        await checker.check(quietly: true)
        XCTAssertEqual(recorder.count, 0)
        XCTAssertNil(checker.available)
        XCTAssertNil(checker.status)
    }

    @MainActor
    func testStartPeriodicChecksWithoutChannelSchedulesNothing() async {
        let recorder = FetchRecorder()
        let checker = UpdateChecker(channel: nil, runningTeamID: "ABCDE12345",
                                    fetch: recorder.fetch)

        checker.startPeriodicChecks()
        // Give any task it might have spawned a chance to run.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(checker.isCheckingPeriodically, "no hourly timer without a channel")
        XCTAssertEqual(recorder.count, 0)
    }

    @MainActor
    func testOpenUpdateWithoutChannelNeverStartsAnInstall() {
        let checker = UpdateChecker(channel: nil, runningTeamID: "ABCDE12345",
                                    fetch: FetchRecorder().fetch)
        // However a release got here, the install path must refuse it.
        checker.available = UpdateChecker.Release(
            version: "99.0.0",
            htmlURL: URL(string: "https://example.invalid/release")!,
            assetURL: URL(string: "https://example.invalid/DreaMail-99.0.0.zip")!,
            checksumURL: URL(string: "https://example.invalid/SHA256SUMS")!,
            notes: "")

        checker.openUpdate()

        XCTAssertNil(checker.available)
        XCTAssertEqual(checker.activity, .idle)
        XCTAssertEqual(checker.status, UpdateChecker.noChannelStatus)
    }

    // MARK: - Ad-hoc signed copy (F-01): a channel alone is not enough

    @MainActor
    func testAdHocCopyWithAChannelStaysInert() async {
        let recorder = FetchRecorder()
        let checker = UpdateChecker(channel: UpdateChannel("bateman/dreamail"),
                                    runningTeamID: nil, fetch: recorder.fetch)
        XCTAssertEqual(checker.availability, .unsignedInstall)
        XCTAssertFalse(checker.isEnabled)
        XCTAssertNil(checker.channel)

        checker.startPeriodicChecks()
        await checker.check(quietly: true)
        await checker.check(quietly: false)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(recorder.count, 0, "an ad-hoc copy must never ask for a release")
        XCTAssertFalse(checker.isCheckingPeriodically)
        XCTAssertNil(checker.available)
        XCTAssertEqual(checker.status, UpdateChecker.unsignedInstallStatus)
        XCTAssertEqual(checker.disabledStatus, UpdateChecker.unsignedInstallStatus)
    }

    @MainActor
    func testAdHocCopyNeverStartsAnInstall() {
        let checker = UpdateChecker(channel: UpdateChannel("bateman/dreamail"),
                                    runningTeamID: nil, fetch: FetchRecorder().fetch)
        checker.available = UpdateChecker.Release(
            version: "99.0.0",
            htmlURL: URL(string: "https://example.invalid/release")!,
            assetURL: URL(string: "https://example.invalid/DreaMail-99.0.0.zip")!,
            checksumURL: nil, notes: "")

        checker.openUpdate()

        XCTAssertNil(checker.available)
        XCTAssertEqual(checker.activity, .idle)
        XCTAssertEqual(checker.status, UpdateChecker.unsignedInstallStatus)
    }

    @MainActor
    func testAvailabilityNeedsBothAChannelAndATeam() {
        let channel = UpdateChannel("bateman/dreamail")!
        let cases: [(UpdateChannel?, String?, UpdateChecker.Availability)] = [
            (nil, nil, .noChannel),
            (nil, "ABCDE12345", .noChannel),
            (channel, nil, .unsignedInstall),
            (channel, "ABCDE12345", .enabled(channel)),
        ]
        for (channel, team, expected) in cases {
            let checker = UpdateChecker(channel: channel, runningTeamID: team,
                                        fetch: FetchRecorder().fetch)
            XCTAssertEqual(checker.availability, expected)
        }
    }

    // MARK: - Updater with a channel

    @MainActor
    func testConfiguredChannelQueriesExactlyThatRepository() async throws {
        let recorder = FetchRecorder(body: """
            {"tag_name": "v99.0.0", "html_url": "https://github.com/bateman/dreamail/releases/tag/v99.0.0",
             "body": "notes", "assets": [
               {"name": "DreaMail-99.0.0.zip", "browser_download_url": "https://example.invalid/DreaMail-99.0.0.zip"},
               {"name": "SHA256SUMS", "browser_download_url": "https://example.invalid/SHA256SUMS"}]}
            """)
        let checker = UpdateChecker(channel: UpdateChannel("bateman/dreamail"),
                                    runningTeamID: "ABCDE12345", fetch: recorder.fetch)
        XCTAssertTrue(checker.isEnabled)

        await checker.check(quietly: false)

        XCTAssertEqual(recorder.urls.map(\.absoluteString),
                       ["https://api.github.com/repos/bateman/dreamail/releases/latest"])
        let release = try XCTUnwrap(checker.available)
        XCTAssertEqual(release.version, "99.0.0")
        XCTAssertEqual(release.assetURL?.lastPathComponent, "DreaMail-99.0.0.zip")
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
