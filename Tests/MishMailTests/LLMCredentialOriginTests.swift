import XCTest

/// A saved provider key or sign-in goes only to the origin (scheme, host and
/// port) it was given for: model discovery, the connection check and
/// generation all pass `LLMClient.authorize` first (F-12).
///
/// The client runs with the AI features on, an injected Keychain that holds
/// a key for every provider, and a transport that records every request, so
/// "the key was never sent" reads as zero transport calls.
final class LLMCredentialOriginTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var net: LLMRecordingTransport!
    private var secrets: LLMRecordingSecrets!
    private var client: LLMClient!

    override func setUp() {
        super.setUp()
        suite = "LLMCredentialOriginTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        net = LLMRecordingTransport()
        secrets = LLMRecordingSecrets()
        client = LLMClient(enabled: true, transport: net.transport,
                           secrets: secrets.reader, defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func saved(_ baseURL: String, kind: LLMProviderKind = .openAICompatible,
                       auth: LLMAuthMode = .apiKey) -> LLMProviderConfig {
        let config = LLMProviderConfig(id: UUID(), kind: kind, label: "Saved",
                                       baseURL: baseURL, defaultModel: "model-a",
                                       authMode: auth)
        var rows = LLMProviderStore.load(from: defaults)
        rows.append(config)
        LLMProviderStore.save(rows, to: defaults)
        return config
    }

    private func edited(_ config: LLMProviderConfig, to baseURL: String) -> LLMProviderConfig {
        var copy = config
        copy.baseURL = baseURL
        return copy
    }

    // MARK: - Fetch models with an edited, unsaved Base URL

    /// The F-12 path: edit a saved provider's Base URL in the sheet, leave
    /// the key field empty, press Fetch models. Even with the new host
    /// confirmed in the sheet, the saved key must not go there.
    func testFetchModelsNeverSendsTheSavedKeyToAnEditedOrigin() async {
        let openAI = saved("https://api.openai.com/v1")
        let custom = saved("https://llm.mine.example/v1")
        LLMProviderStore.setConsentedHost(LLMRemotePolicy.origin(of: custom.baseURL),
                                          for: custom.id, to: defaults)
        let cases: [(LLMProviderConfig, String)] = [
            (openAI, "https://collector.example/v1"),       // new host
            (openAI, "https://api.groq.com/openai/v1"),     // another preset host
            (custom, "https://llm.mine.example:8443/v1"),   // new port
            (custom, "https://other.mine.example/v1"),      // new host, same domain
        ]
        for (config, url) in cases {
            let moved = edited(config, to: url)
            do {
                _ = try await client.listModels(
                    config: moved, sheetConsent: LLMRemotePolicy.origin(of: url))
                XCTFail("\(url): the saved key was accepted for a new origin")
            } catch {
                guard case LLMClientError.credentialNotAuthorized = error else {
                    XCTFail("\(url): unexpected \(error)")
                    continue
                }
            }
        }
        XCTAssertEqual(net.requests.count, 0, "zero transport calls to a new origin")
        XCTAssertEqual(secrets.reads, [], "the key is not even read")
    }

    func testGenerationNeverSendsTheSavedKeyToAnEditedOrigin() async {
        let config = saved("https://api.anthropic.com", kind: .anthropic)
        let moved = edited(config, to: "https://api.openai.com/v1")
        do {
            for try await _ in await client.stream(
                messages: [LLMMessage(role: .user, text: "private mail text")],
                tools: [], config: moved, model: "model-a", task: .drafts) {}
            XCTFail("generation used the saved key at a new origin")
        } catch {
            guard case LLMClientError.credentialNotAuthorized = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(net.requests.count, 0)
    }

    func testSignInTokensAreBoundToo() async {
        let config = saved("https://api.openai.com/v1", auth: .oauth(.chatGPT))
        do {
            _ = try await client.listModels(config: edited(config, to: "https://evil.example/v1"),
                                            sheetConsent: "https://evil.example:443")
            XCTFail("sign-in tokens went to a new origin")
        } catch {
            guard case LLMClientError.credentialNotAuthorized = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(net.requests.count, 0)
        XCTAssertEqual(secrets.reads, [])
    }

    // MARK: - What still works

    func testTheSavedOriginStillGetsTheKey() async throws {
        let config = saved("https://api.openai.com/v1")
        let models = try await client.listModels(config: config)
        XCTAssertEqual(models, ["model-a"])
        XCTAssertEqual(net.requests.count, 1)
        XCTAssertEqual(net.requests.first?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer \(secrets.value)")
        // A trailing slash or explicit default port is the same origin.
        _ = try await client.listModels(config: edited(config, to: "https://API.openai.com:443/v1/"))
        XCTAssertEqual(net.requests.count, 2)
    }

    func testGenerationAtTheSavedOriginReachesTheTransport() async {
        let config = saved("https://api.openai.com/v1")
        do {
            for try await _ in await client.stream(
                messages: [LLMMessage(role: .user, text: "hi")],
                tools: [], config: config, model: "model-a", task: .drafts) {}
        } catch {}
        XCTAssertEqual(net.requests.count, 1)
        XCTAssertEqual(net.requests.first?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer \(secrets.value)")
    }

    /// A key typed in the sheet for a new provider is recorded with the
    /// origin it was typed for; that origin may use it, no other may.
    func testRecordedOriginOfANewKey() async throws {
        let draft = LLMProviderConfig(id: UUID(), kind: .openAICompatible, label: "New",
                                      baseURL: "https://llm.new.example/v1",
                                      defaultModel: "m", authMode: .apiKey)
        let origin = try XCTUnwrap(LLMRemotePolicy.origin(of: draft.baseURL))
        // No saved row and no record: nothing is authorised.
        XCTAssertFalse(LLMProviderStore.credentialMayBeSent(for: draft, from: defaults))
        LLMProviderStore.setCredentialOrigin(origin, for: draft.id, to: defaults)
        XCTAssertTrue(LLMProviderStore.credentialMayBeSent(for: draft, from: defaults))
        _ = try await client.listModels(config: draft, sheetConsent: origin)
        XCTAssertEqual(net.requests.count, 1)

        let moved = edited(draft, to: "https://llm.new.example:444/v1")
        XCTAssertFalse(LLMProviderStore.credentialMayBeSent(for: moved, from: defaults))
    }

    /// A recorded origin wins over the saved row: re-pointing a row's Base
    /// URL (a Save that kept the old key) does not re-authorise the key.
    func testRecordedOriginOutlivesABaseURLChangeOfTheRow() {
        let config = saved("https://api.x.ai/v1")
        LLMProviderStore.setCredentialOrigin(LLMRemotePolicy.origin(of: config.baseURL),
                                             for: config.id, to: defaults)
        let moved = edited(config, to: "https://api.openai.com/v1")
        LLMProviderStore.save([moved], to: defaults)
        XCTAssertFalse(LLMProviderStore.credentialMayBeSent(for: moved, from: defaults))
        LLMProviderStore.setCredentialOrigin(nil, for: config.id, to: defaults)
        // With no record, the row's own origin is the authorised one.
        XCTAssertTrue(LLMProviderStore.credentialMayBeSent(for: moved, from: defaults))
    }

    func testCustomHostStillNeedsConsentBeforeAnything() async {
        let config = saved("https://llm.unconfirmed.example/v1")
        do {
            _ = try await client.listModels(config: config)
            XCTFail("listing must need consent for a custom host")
        } catch {
            guard case LLMClientError.untrustedEndpoint = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertEqual(net.requests.count, 0)
    }
}
