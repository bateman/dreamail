import XCTest

final class HTMLBodyCSPTests: XCTestCase {
    func testBlocksBaseURIAndForms() {
        let csp = HTMLBodyCSP.metaTag(allowRemoteImages: false)
        XCTAssertTrue(csp.contains("default-src 'none'"))
        XCTAssertTrue(csp.contains("base-uri 'none'"))
        XCTAssertTrue(csp.contains("form-action 'none'"))
        XCTAssertTrue(csp.contains("frame-src 'none'"))
        XCTAssertTrue(csp.contains("object-src 'none'"))
        XCTAssertTrue(csp.contains("style-src 'unsafe-inline'"))
    }

    func testRemoteImagesAreHTTPSOnly() {
        let blocked = HTMLBodyCSP.metaTag(allowRemoteImages: false)
        XCTAssertTrue(blocked.contains("img-src data: cid:"))
        XCTAssertFalse(blocked.contains("img-src data: cid: https:"))
        // Scheme tokens only — don't match the meta's `http-equiv` attribute.
        XCTAssertFalse(blocked.contains(" https:"))
        XCTAssertFalse(blocked.contains(" http:"))

        let allowed = HTMLBodyCSP.metaTag(allowRemoteImages: true)
        XCTAssertTrue(allowed.contains("img-src data: cid: https:"))
        // Cleartext image loads stay banned even when remote images are on.
        XCTAssertFalse(allowed.contains(" http:"))
    }

    /// Both variants pinned exactly: turning remote images on by default must
    /// not change what either policy admits.
    func testCSPStringsArePinned() {
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
}
