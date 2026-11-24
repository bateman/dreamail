import XCTest

/// Consent to send mail to a custom host is bound to its full origin:
/// a change of scheme, host or port needs a new confirm, also when the stored
/// record is a legacy host-only one (F-06).
final class LLMConsentOriginTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "LLMConsentOriginTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func savedCustom(_ baseURL: String = "https://llm.mine.example/v1") -> LLMProviderConfig {
        let config = LLMProviderConfig(id: UUID(), kind: .openAICompatible, label: "Proxy",
                                       baseURL: baseURL, defaultModel: "m", authMode: .apiKey)
        LLMProviderStore.save([config], to: defaults)
        return config
    }

    private func moved(_ config: LLMProviderConfig, _ baseURL: String) -> LLMProviderConfig {
        var copy = config
        copy.baseURL = baseURL
        return copy
    }

    // MARK: - Legacy host-only record

    /// The F-06 case: an older build stored only the host. Before the fix
    /// that record matched any URL with the same host, so a scheme or port
    /// change (or an edited URL the sheet then saved) kept consent.
    func testLegacyHostOnlyConsentDoesNotCoverAnotherSchemeOrPort() {
        let config = savedCustom()
        LLMProviderStore.setConsentedHost("llm.mine.example", for: config.id, to: defaults)

        // It still covers the saved row's own origin, so existing setups keep working.
        XCTAssertTrue(LLMProviderStore.hasHostConsent(for: config, from: defaults))
        XCTAssertEqual(LLMProviderStore.consentedOrigin(for: config.id, from: defaults),
                       "https://llm.mine.example:443")

        for url in ["https://llm.mine.example:8443/v1",   // port
                    "http://llm.mine.example/v1",          // scheme
                    "http://llm.mine.example:443/v1",      // scheme, same port
                    "https://other.mine.example/v1"] {     // host
            XCTAssertFalse(LLMProviderStore.hasHostConsent(for: moved(config, url), from: defaults),
                           url)
        }
    }

    /// The record migrates only to the saved row's origin: once the row
    /// itself points elsewhere, the old host-only record covers nothing.
    func testLegacyHostOnlyConsentDoesNotFollowARowThatMoved() {
        let config = savedCustom("https://new.mine.example/v1")
        LLMProviderStore.setConsentedHost("llm.mine.example", for: config.id, to: defaults)
        XCTAssertFalse(LLMProviderStore.hasHostConsent(for: config, from: defaults))
        XCTAssertFalse(LLMProviderStore.hasHostConsent(
            for: moved(config, "https://llm.mine.example/v1"), from: defaults))
        XCTAssertNil(LLMProviderStore.consentedOrigin(for: config.id, from: defaults))
    }

    func testLegacyHostOnlyConsentWithoutASavedRowCoversNothing() {
        let draft = LLMProviderConfig(id: UUID(), kind: .openAICompatible, label: "Draft",
                                      baseURL: "https://llm.mine.example/v1",
                                      defaultModel: "m", authMode: .apiKey)
        LLMProviderStore.setConsentedHost("llm.mine.example", for: draft.id, to: defaults)
        XCTAssertFalse(LLMProviderStore.hasHostConsent(for: draft, from: defaults))
    }

    // MARK: - Full-origin record

    func testFullOriginConsentIsExact() {
        let config = savedCustom()
        LLMProviderStore.setConsentedHost(LLMRemotePolicy.origin(of: config.baseURL),
                                          for: config.id, to: defaults)
        XCTAssertTrue(LLMProviderStore.hasHostConsent(for: config, from: defaults))
        XCTAssertTrue(LLMProviderStore.hasHostConsent(
            for: moved(config, "https://LLM.mine.example:443/other/"), from: defaults))
        XCTAssertFalse(LLMProviderStore.hasHostConsent(
            for: moved(config, "https://llm.mine.example:444/v1"), from: defaults))
    }

    // MARK: - What the sheet saves

    /// Save persists consent only for the origin the toggle was turned on
    /// for, and only while the Base URL still has that origin; anything else
    /// clears the record.
    func testSaveKeepsConsentOnlyForTheConfirmedOrigin() {
        let a = "https://llm.mine.example:443"
        let b = "https://llm.mine.example:8443"
        XCTAssertEqual(LLMProviderStore.consentToSave(confirmed: a, saving: a), a)
        XCTAssertNil(LLMProviderStore.consentToSave(confirmed: a, saving: b))
        XCTAssertNil(LLMProviderStore.consentToSave(confirmed: nil, saving: b))
        XCTAssertNil(LLMProviderStore.consentToSave(confirmed: a, saving: nil))

        // Saving with a cleared consent drops a legacy record for good.
        let config = savedCustom()
        LLMProviderStore.setConsentedHost("llm.mine.example", for: config.id, to: defaults)
        LLMProviderStore.setConsentedHost(
            LLMProviderStore.consentToSave(confirmed: a, saving: b), for: config.id, to: defaults)
        XCTAssertNil(LLMProviderStore.consentedHost(for: config.id, from: defaults))
        XCTAssertFalse(LLMProviderStore.hasHostConsent(for: config, from: defaults))
    }
}
