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

    func testDisabledSignInAndRefreshPostsSendNothing() async {
        let net = LLMRecordingTransport()
        await assertAIDisabled("form") {
            _ = try await LLMClient.postForm("https://auth.example/token", ["a": "b"],
                                             enabled: false, transport: net.transport)
        }
        await assertAIDisabled("raw form") {
            _ = try await LLMClient.postFormRaw("https://auth.example/token", ["a": "b"],
                                                enabled: false, transport: net.transport)
        }
        await assertAIDisabled("json") {
            _ = try await LLMClient.postJSON("https://auth.example/token", ["a": "b"],
                                             enabled: false, transport: net.transport)
        }
        for vendor in [LLMOAuthVendor.claude, .chatGPT, .grok, .gemini, .openRouter] {
            await assertAIDisabled("\(vendor)") {
                _ = try await LLMClient.postToken(vendor: vendor, ["refresh_token": "r"],
                                                  enabled: false, transport: net.transport)
            }
        }
        XCTAssertEqual(net.requests.count, 0)
    }

    @MainActor
    func testDisabledSignInFlowStartsNoListener() async {
        // The process-wide switch: off in every build of this repository.
        guard !AIFeatures.isEnabled else { return }
        do {
            try await LLMOAuthFlow.signIn(vendor: .claude, providerID: UUID())
            XCTFail("sign-in must refuse")
        } catch {
            guard case LLMClientError.aiDisabled = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testDisabledOllamaSendsNothing() async {
        let net = LLMRecordingTransport()
        let request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!)
        do {
            _ = try await Ollama.send(request, enabled: false, transport: net.ollamaTransport)
            XCTFail("Ollama.send must refuse")
        } catch {
            guard case Ollama.OllamaError.aiDisabled = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(net.requests.count, 0)
        _ = try? await Ollama.send(request, enabled: true, transport: net.ollamaTransport)
        XCTAssertEqual(net.requests.count, 1)
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
        do {
            _ = try await LLMTaskRunner.generate(task: .triage, prompt: "private", enabled: false)
            XCTFail("generate must fail")
        } catch {
            guard case LLMClientError.aiDisabled = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testAutoSortNeverRunsWithTheFeaturesOff() {
        defaults.set(true, forKey: AITriage.autoClassifyKey)
        XCTAssertFalse(AITriage.isAutoClassifyEnabled(defaults, aiFeatures: false))
        XCTAssertTrue(AITriage.isAutoClassifyEnabled(defaults, aiFeatures: true))
        defaults.set(false, forKey: AITriage.autoClassifyKey)
        XCTAssertFalse(AITriage.isAutoClassifyEnabled(defaults, aiFeatures: true))
    }

    // MARK: - MCP server

    func testMCPServerDoesNotStartWithStoredOptInWhenTheFeaturesAreOff() {
        defaults.set(true, forKey: MCPLaunchPolicy.enabledKey)
        XCTAssertFalse(MCPLaunchPolicy.shouldStartAtLaunch(aiFeatures: false, defaults: defaults))
        var started = 0
        let ran = MCPLaunchPolicy.startIfAllowed(aiFeatures: false) { started += 1 }
        XCTAssertFalse(ran)
        XCTAssertEqual(started, 0, "no listener, no token read, no mcp.json")
        XCTAssertFalse(MCPLaunchPolicy.mayRun(aiFeatures: false))
    }

    func testMCPServerStartsOnlyWhenBothTheBuildAndTheUserSaySo() {
        XCTAssertFalse(MCPLaunchPolicy.shouldStartAtLaunch(aiFeatures: true, defaults: defaults))
        defaults.set(true, forKey: MCPLaunchPolicy.enabledKey)
        XCTAssertTrue(MCPLaunchPolicy.shouldStartAtLaunch(aiFeatures: true, defaults: defaults))
        var started = 0
        XCTAssertTrue(MCPLaunchPolicy.startIfAllowed(aiFeatures: true) { started += 1 })
        XCTAssertEqual(started, 1)
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
