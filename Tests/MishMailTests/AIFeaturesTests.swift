import XCTest

/// The build-time switch that keeps the AI features and the MCP server off
/// (`AIFeatures`). With it off, nothing reaches a model provider, the Ollama
/// daemon or a sign-in endpoint, no stored credential is read, and the MCP
/// server does not start whatever `mcp.enabled` says.
///
/// Each gated type takes the switch as a parameter, so these tests drive both
/// states; the shipped configuration is checked against the tracked files.
final class AIFeaturesTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "AIFeaturesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: - The value

    func testOnlyAnExplicitYesTurnsTheFeaturesOn() {
        for raw in ["YES", "yes", "true", "1", " YES\n"] {
            XCTAssertTrue(AIFeatures.isOn(raw), raw)
        }
        for raw in [nil, "", "NO", "0", "false", "$(MISHMAIL_AI_FEATURES)", "on", "enabled"] {
            XCTAssertFalse(AIFeatures.isOn(raw), String(describing: raw))
        }
        XCTAssertFalse(AIFeatures.configured(in: nil))
        XCTAssertFalse(AIFeatures.configured(in: [:]))
        XCTAssertFalse(AIFeatures.configured(in: [AIFeatures.infoKey: 1]))
        XCTAssertTrue(AIFeatures.configured(in: [AIFeatures.infoKey: "YES"]))
    }

    /// Info.plist only forwards the build setting, the tracked xcconfig sets
    /// it to empty before the untracked Local.xcconfig, and no target setting
    /// in project.yml can override it.
    func testTrackedConfigurationShipsWithTheFeaturesOff() throws {
        let plistData = try Data(contentsOf: ForkIdentityTests.repoRoot
            .appendingPathComponent("Sources/MishMail/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: plistData, format: nil) as? [String: Any])
        XCTAssertEqual(plist[AIFeatures.infoKey] as? String, "$(MISHMAIL_AI_FEATURES)")

        let xcconfig = try ForkIdentityTests.repoFile("Config/Signing.xcconfig")
        let lines = xcconfig.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let assignments = lines.filter { !$0.hasPrefix("//") && $0.hasPrefix("MISHMAIL_AI_FEATURES") }
        XCTAssertEqual(assignments, ["MISHMAIL_AI_FEATURES ="])
        let assignment = try XCTUnwrap(lines.firstIndex(of: "MISHMAIL_AI_FEATURES ="))
        let include = try XCTUnwrap(lines.firstIndex(of: "#include? \"Local.xcconfig\""))
        XCTAssertLessThan(assignment, include, "Local.xcconfig must be able to override it")

        XCTAssertFalse(try ForkIdentityTests.repoFile("project.yml").contains("MISHMAIL_AI_FEATURES"))
    }

    /// `make install` and `make release` build apps that leave this Mac. A
    /// Config/Local.xcconfig with MISHMAIL_AI_FEATURES = YES (it is needed
    /// there for the signing team) must not reach them: both pass the tracked
    /// value on the xcodebuild command line, which wins over every xcconfig,
    /// and check the built Info.plist before installing or publishing.
    func testInstallAndReleaseTakeTheSwitchFromTheTrackedConfigurationOnly() throws {
        let makefile = try ForkIdentityTests.repoFile("Makefile")
        XCTAssertTrue(makefile.contains(
            "TRACKED_AI_FEATURES := $(shell awk -F= '/^[ \\t]*MISHMAIL_AI_FEATURES[ \\t]*=/"))
        XCTAssertTrue(makefile.contains("Config/Signing.xcconfig)\nSHIP_AI_FLAGS = MISHMAIL_AI_FEATURES=$(TRACKED_AI_FEATURES)\n"))

        func recipe(_ target: String) throws -> String {
            let start = try XCTUnwrap(makefile.range(of: "\n\(target):"), target)
            let rest = makefile[start.upperBound...]
            let end = rest.range(of: "\n\n")?.lowerBound ?? rest.endIndex
            return String(rest[..<end])
        }
        for (target, app) in [("install", "RELEASE_APP"), ("release", "SHIP_APP")] {
            let body = try recipe(target)
            let builds = body.components(separatedBy: "xcodebuild build").dropFirst()
            XCTAssertFalse(builds.isEmpty, target)
            for build in builds {
                let command = build.components(separatedBy: "\n")
                    .prefix { !$0.contains("$(call") && !$0.hasPrefix("\telse") && !$0.hasPrefix("\tfi") }
                    .joined(separator: "\n")
                XCTAssertTrue(command.contains("$(SHIP_AI_FLAGS)"), "\(target): \(command)")
            }
            let check = try XCTUnwrap(body.range(of: "$(call check_ai_switch,$(\(app)))"),
                                      "\(target) does not check the built app")
            let ship = target == "install" ? "ditto \"$(RELEASE_APP)\" /Applications" : "gh release create"
            let shipAt = try XCTUnwrap(body.range(of: ship), target)
            XCTAssertLessThan(check.lowerBound, shipAt.lowerBound, "\(target) checks after shipping")
        }
        XCTAssertTrue(makefile.contains(
            "plutil -extract MishMailAIFeatures raw \"$(1)/Contents/Info.plist\""))
    }

    // MARK: - LLM client: zero requests, zero credential reads

    private func provider(_ baseURL: String = "https://api.openai.com/v1",
                          kind: LLMProviderKind = .openAICompatible,
                          auth: LLMAuthMode = .apiKey) -> LLMProviderConfig {
        LLMProviderConfig(id: UUID(), kind: kind, label: "P", baseURL: baseURL,
                          defaultModel: "model-a", authMode: auth)
    }

    func testDisabledClientSendsNothingAndReadsNoCredential() async throws {
        let net = LLMRecordingTransport()
        let secrets = LLMRecordingSecrets()
        let client = LLMClient(enabled: false, transport: net.transport,
                               secrets: secrets.reader, defaults: defaults)
        let configs = [
            provider(),
            provider("https://api.anthropic.com", kind: .anthropic),
            provider("https://api.anthropic.com", kind: .anthropic, auth: .oauth(.claude)),
            provider("https://llm.custom.example/v1"),
            LLMProviderStore.builtInOllama(),
        ]
        for config in configs {
            LLMProviderStore.save([config], to: defaults)
            await assertAIDisabled(config.baseURL) {
                _ = try await client.listModels(config: config)
            }
            await assertAIDisabled(config.baseURL) {
                for try await _ in await client.stream(
                    messages: [LLMMessage(role: .user, text: "private mail text")],
                    tools: [], config: config, model: "model-a", task: .askMish) {}
            }
        }
        XCTAssertEqual(net.requests.count, 0)
        XCTAssertEqual(secrets.reads, [], "no stored credential may be read")
    }

    func testEnabledClientDoesSendSoTheGateIsWhatStopsIt() async throws {
        let net = LLMRecordingTransport()
        let config = provider()
        LLMProviderStore.save([config], to: defaults)
        let client = LLMClient(enabled: true, transport: net.transport,
                               secrets: LLMRecordingSecrets().reader, defaults: defaults)
        let models = try await client.listModels(config: config)
        XCTAssertEqual(models, ["model-a"])
        XCTAssertEqual(net.requests.count, 1)
    }

    /// The network gate itself: what every AI request (provider, sign-in,
    /// refresh, Ollama) goes through in the app as `LLMTransport.live`.
    func testGatedTransportSendsNothingWhenOff() async {
        let net = LLMRecordingTransport()
        let off = LLMTransport.gated(enabled: false, net.transport)
        let request = URLRequest(url: URL(string: "https://api.example/v1/models")!)
        await assertAIDisabled("data") { _ = try await off.data(request) }
        await assertAIDisabled("bytes") { _ = try await off.bytes(request) }
        XCTAssertEqual(net.requests.count, 0)
        let on = LLMTransport.gated(enabled: true, net.transport)
        _ = try? await on.data(request)
        XCTAssertEqual(net.requests.count, 1)
    }

    func testSignInRefreshAndOllamaPostsGoThroughTheGate() async {
        let net = LLMRecordingTransport()
        let off = LLMTransport.gated(enabled: false, net.transport)
        await assertAIDisabled("form") {
            _ = try await LLMClient.postForm("https://auth.example/token", ["a": "b"], transport: off)
        }
        await assertAIDisabled("raw form") {
            _ = try await LLMClient.postFormRaw("https://auth.example/token", ["a": "b"],
                                                transport: off)
        }
        await assertAIDisabled("json") {
            _ = try await LLMClient.postJSON("https://auth.example/token", ["a": "b"], transport: off)
        }
        for vendor in [LLMOAuthVendor.claude, .chatGPT, .grok, .gemini, .openRouter] {
            await assertAIDisabled("\(vendor)") {
                _ = try await LLMClient.postToken(vendor: vendor, ["refresh_token": "r"],
                                                  transport: off)
            }
        }
        await assertAIDisabled("ollama") {
            _ = try await Ollama.send(
                URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!), transport: off)
        }
        XCTAssertEqual(net.requests.count, 0)
    }

    @MainActor
    func testDisabledSignInFlowStartsNoListener() async {
        do {
            try await LLMOAuthFlow.signIn(vendor: .claude, providerID: UUID(), enabled: false)
            XCTFail("sign-in must refuse")
        } catch {
            guard case LLMClientError.aiDisabled = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    @MainActor
    func testDisabledTaskRunnerEndsBeforeResolvingAProvider() async {
        do {
            for try await _ in LLMTaskRunner.stream(task: .summaries, prompt: "private",
                                                    enabled: false) {
                XCTFail("no token may arrive")
            }
            XCTFail("the stream must fail")
        } catch {
            guard case LLMClientError.aiDisabled = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    // MARK: - Redirects (AI-on correctness)

    /// URLSession would follow a 307/308 and resend the mail text and the
    /// key headers to the new origin. The guard follows same-origin only.
    func testRedirectGuardFollowsOnlyTheSameOrigin() {
        let guardDelegate = LLMRedirectGuard()
        let task = URLSession.shared.dataTask(
            with: URL(string: "https://api.example/v1/chat/completions")!)
        defer { task.cancel() }
        let response = HTTPURLResponse(url: URL(string: "https://api.example/v1/chat/completions")!,
                                       statusCode: 307, httpVersion: nil, headerFields: nil)!
        func decision(_ target: String) -> URLRequest? {
            var followed: URLRequest?? = .none
            guardDelegate.urlSession(URLSession.shared, task: task,
                                     willPerformHTTPRedirection: response,
                                     newRequest: URLRequest(url: URL(string: target)!)) {
                followed = .some($0)
            }
            guard case .some(let request) = followed else {
                XCTFail("completion handler not called for \(target)")
                return nil
            }
            return request
        }
        XCTAssertNotNil(decision("https://api.example/v2/chat/completions"))
        XCTAssertNotNil(decision("https://API.example:443/v1/other"))
        for target in ["https://collector.example/v1/chat/completions",
                       "https://api.example:8443/v1/chat/completions",
                       "http://api.example/v1/chat/completions",
                       "http://127.0.0.1:11434/api/chat"] {
            XCTAssertNil(decision(target), target)
        }
        XCTAssertFalse(LLMRedirectGuard.allows(from: nil, to: URL(string: "https://api.example")))
    }

    // MARK: - MCP server state left by an earlier build

    private func tempDiscovery() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIFeaturesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("mcp.json")
    }

    /// With the features off, a stored opt-in is cleared (no silent restart
    /// when they come back), a stale mcp.json goes, and the token is marked
    /// for rotation on the next opt-in.
    func testSwitchedOffLaunchClearsTheOptInAndTheDiscoveryFile() throws {
        let discovery = try tempDiscovery()
        try Data(#"{"port":41888,"pid":1}"#.utf8).write(to: discovery)
        defaults.set(true, forKey: MCPSwitchedOff.enabledKey)

        XCTAssertTrue(MCPSwitchedOff.cleanUp(defaults: defaults, discoveryURL: discovery))
        XCTAssertNil(defaults.object(forKey: MCPSwitchedOff.enabledKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: discovery.path))
        XCTAssertTrue(MCPSwitchedOff.takeTokenRotation(defaults: defaults))
        XCTAssertFalse(MCPSwitchedOff.takeTokenRotation(defaults: defaults), "once")
    }

    func testSwitchedOffLaunchWithNothingStoredChangesNothing() throws {
        let discovery = try tempDiscovery()
        XCTAssertFalse(MCPSwitchedOff.cleanUp(defaults: defaults, discoveryURL: discovery))
        XCTAssertFalse(MCPSwitchedOff.takeTokenRotation(defaults: defaults))
        defaults.set(false, forKey: MCPSwitchedOff.enabledKey)
        XCTAssertFalse(MCPSwitchedOff.cleanUp(defaults: defaults, discoveryURL: discovery))
        XCTAssertNil(defaults.object(forKey: MCPSwitchedOff.enabledKey))
    }

    func testStaleDiscoverySymlinkIsRemovedNotFollowed() throws {
        let discovery = try tempDiscovery()
        let target = discovery.deletingLastPathComponent().appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: discovery, withDestinationURL: target)
        XCTAssertTrue(MCPSwitchedOff.cleanUp(defaults: defaults, discoveryURL: discovery))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: discovery.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: - Surfaces

    func testPaletteListsAskMishAndAISortOnlyWithTheFeaturesOn() {
        var ctx = PaletteCommands.Context()
        ctx.aiFeatures = false
        let off = Set(PaletteCommands.entries(ctx).map(\.id))
        XCTAssertFalse(off.contains("askmish"))
        XCTAssertFalse(off.contains("aisort"))
        XCTAssertTrue(off.contains("compose"))
        XCTAssertTrue(off.contains("newview"))
        ctx.aiFeatures = true
        let on = PaletteCommands.entries(ctx).map(\.id)
        XCTAssertTrue(on.contains("askmish"))
        XCTAssertTrue(on.contains("aisort"))
        XCTAssertEqual(Set(on).count, on.count)
    }

    func testComposeOffersNoAIToolWithTheFeaturesOff() {
        XCTAssertFalse(ComposeToolbarVisibility.isOffered(.ai, aiFeatures: false))
        XCTAssertTrue(ComposeToolbarVisibility.isOffered(.ai, aiFeatures: true))
        XCTAssertTrue(ComposeToolbarVisibility.isOffered(.attach, aiFeatures: false))
        XCTAssertFalse(ComposeToolbarVisibility.settingsItems(aiFeatures: false).contains(.ai))
        XCTAssertEqual(ComposeToolbarVisibility.settingsItems(aiFeatures: true),
                       ComposeToolbarItem.displayOrder)
    }

    // MARK: - Helpers

    private func assertAIDisabled(_ label: String,
                                  file: StaticString = #filePath, line: UInt = #line,
                                  _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("\(label): expected the AI switch to refuse", file: file, line: line)
        } catch {
            guard case LLMClientError.aiDisabled = error else {
                return XCTFail("\(label): unexpected \(error)", file: file, line: line)
            }
        }
    }
}
