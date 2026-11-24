import XCTest

/// `GmailError.http`'s text reaches banners, compose errors and MCP / Ask
/// Mish tool results; it must never carry the raw response body.
final class GmailErrorDescriptionTests: XCTestCase {

    private func text(_ code: Int, _ body: String) -> String {
        GmailError.http(code, body).localizedDescription
    }

    func testShowsStatusReasonAndGoogleMessageButNotTheJSON() {
        let body = #"""
        {"error":{"code":400,"message":"Invalid To header",
        "errors":[{"message":"Invalid To header","domain":"global","reason":"invalidArgument"}],
        "status":"INVALID_ARGUMENT"}}
        """#
        XCTAssertEqual(text(400, body), "Gmail API error 400 (invalidArgument): Invalid To header")
    }

    func testRawBodyFieldsNeverAppear() {
        let body = #"{"error":{"code":403,"message":"Quota exceeded","errors":[{"reason":"rateLimitExceeded","domain":"usageLimits","extendedHelp":"https://example.com/18c2f0a9b7d1e3f4"}]}}"#
        let shown = text(403, body)
        for raw in ["{", "\"", "usageLimits", "extendedHelp", "18c2f0a9b7d1e3f4", "https://"] {
            XCTAssertFalse(shown.contains(raw), "shown \(raw): \(shown)")
        }
        XCTAssertEqual(shown, "Gmail API error 403 (rateLimitExceeded): Quota exceeded")
    }

    func testLongOrMultilineMessageIsFlattenedAndClipped() {
        let long = "line one\nline two\t" + String(repeating: "x", count: 400)
        let body = #"{"error":{"code":400,"message":"\#(long.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t"))"}}"#
        let shown = text(400, body)
        XCTAssertFalse(shown.contains("\n"))
        XCTAssertTrue(shown.contains("line one line two"))
        XCTAssertTrue(shown.hasSuffix("…"))
        XCTAssertLessThanOrEqual(shown.count, "Gmail API error 400: ".count + GmailError.maxMessageChars + 1)
    }

    func testNonJSONBodyFallsBackToAStatusHint() {
        let html = "<html><body><h1>502 Bad Gateway</h1>" + String(repeating: "z", count: 2000) + "</body></html>"
        let shown = text(502, html)
        XCTAssertEqual(shown, "Gmail API error 502: Google's servers had a problem. Try again shortly.")
        XCTAssertEqual(text(418, "teapot"), "Gmail API error 418")
    }

    func testRetryAfterSuffixAndOAuthShapeAreUnderstood() {
        let batch = #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED"}}"# + "\nRetry-After: 30"
        XCTAssertEqual(text(429, batch),
                       "Gmail API error 429 (RESOURCE_EXHAUSTED): too many requests; MishMail will retry.")
        let oauth = #"{"error":"invalid_token","error_description":"Invalid Credentials"}"#
        XCTAssertEqual(text(401, oauth), "Gmail API error 401 (invalid_token): Invalid Credentials")
    }
}
