import XCTest

/// `RemoteImageHTML`: which remote image URLs the app caches, how a document
/// is rewritten with their `data:` URLs, and when the rewritten document can
/// still reach the network.
final class RemoteImageHTMLTests: XCTestCase {
    private let a = "https://img.example.com/a.png"
    private let b = "https://img.example.com/b.png"
    private let dataA = "data:image/png;base64,QUFB"
    private let dataB = "data:image/png;base64,QkJC"

    private func rewrite(_ html: String, _ map: [String: String]) -> RemoteImageHTML.Result {
        RemoteImageHTML.rewrite(html, dataURLs: map)
    }

    // MARK: Positions

    func testImgSrcIsRewritten() {
        let html = "<p>Hi</p><img alt=\"x\" src=\"\(a)\" width=10>"
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [a])
        let out = rewrite(html, [a: dataA])
        XCTAssertEqual(out.html, "<p>Hi</p><img alt=\"x\" src=\"\(dataA)\" width=10>")
        XCTAssertEqual(out.rewrittenCount, 1)
        XCTAssertFalse(out.needsNetwork)
    }

    func testSingleQuotedAndUnquotedValues() {
        let html = "<img src='\(a)'><img src=\(b)>"
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [a, b])
        let out = rewrite(html, [a: dataA, b: dataB])
        XCTAssertEqual(out.html, "<img src=\"\(dataA)\"><img src=\"\(dataB)\">")
        XCTAssertFalse(out.needsNetwork)
    }

    func testBackgroundAttributeOnAnyElement() {
        let html = "<body background=\"\(a)\"><table><td background='\(b)'>x</td></table></body>"
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [a, b])
        let out = rewrite(html, [a: dataA, b: dataB])
        XCTAssertTrue(out.html.contains("<body background=\"\(dataA)\">"))
        XCTAssertTrue(out.html.contains("<td background=\"\(dataB)\">"))
        XCTAssertFalse(out.needsNetwork)
    }

    func testInlineStyleURLsAreRewrittenAndReencoded() {
        let html = "<div style=\"background-image: url(&quot;\(a)&quot;); color: red\">x</div>"
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [a])
        let out = rewrite(html, [a: dataA])
        XCTAssertEqual(out.html,
                       "<div style=\"background-image: url(&quot;\(dataA)&quot;); color: red\">x</div>")
        XCTAssertFalse(out.needsNetwork)
    }

    func testStyleBlockURLsAreRewrittenButFontsAndImportsAreNot() {
        let font = "https://fonts.example.com/f.woff2"
        let sheet = "https://css.example.com/s.css"
        let html = """
            <style>
            @import url("\(sheet)");
            @font-face { font-family: X; src: url(\(font)) format("woff2"); }
            /* url(https://img.example.com/comment.png) */
            .hero { background: #fff url('\(a)') no-repeat; }
            li { list-style-image: URL(\(b)); }
            .t::after { content: "url(https://img.example.com/string.png)"; }
            </style><p>x</p>
            """
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [a, b])
        let out = rewrite(html, [a: dataA, b: dataB])
        XCTAssertTrue(out.html.contains("url(\"\(dataA)\")"))
        XCTAssertTrue(out.html.contains("url(\"\(dataB)\")"))
        XCTAssertTrue(out.html.contains(font), "font left alone")
        XCTAssertTrue(out.html.contains(sheet), "import left alone")
        XCTAssertFalse(out.needsNetwork, "fonts and sheets are blocked by the CSP anyway")
    }

    func testURLsAreKeyedAsTheWebViewWouldRequestThem() {
        // Entities decoded, surrounding whitespace and inner tabs/newlines dropped.
        let html = "<img src=\" https://img.example.com/a.png?x=1&amp;y=2\n \">"
            + "<img src=\"ht\ttps://img.example.com/b.png\">"
        XCTAssertEqual(RemoteImageHTML.candidates(in: html),
                       ["https://img.example.com/a.png?x=1&y=2", b])
    }

    func testDataCidHTTPAndRelativeURLsAreLeftAlone() {
        let html = """
            <img src="data:image/png;base64,AAAA"><img src="cid:logo@x">\
            <img src="http://img.example.com/clear.png"><img src="/rel.png">\
            <img src="//img.example.com/proto.png"><div style="background:url(data:image/gif;base64,R0)"></div>
            """
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [])
        let out = rewrite(html, [:])
        XCTAssertEqual(out.html, html)
        XCTAssertFalse(out.needsNetwork, "http is blocked by the CSP in every variant")
    }

    func testQuotesInsideURLsCannotBreakOutOfTheAttribute() {
        let quoted = "https://img.example.com/a.png?q=%22x"
        let html = "<img src='https://img.example.com/a.png?q=\"x'>"
        let urls = RemoteImageHTML.candidates(in: html)
        XCTAssertEqual(urls, [quoted])
        let out = rewrite(html, [quoted: dataA])
        XCTAssertEqual(out.html, "<img src=\"\(dataA)\">")
    }

    func testSameURLTwiceIsOneCandidateAndBothAreRewritten() {
        let html = "<img src=\"\(a)\"><td background=\"\(a)\">"
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [a])
        let out = rewrite(html, [a: dataA])
        XCTAssertEqual(out.rewrittenCount, 2)
        XCTAssertFalse(out.html.contains(a))
    }

    func testUnresolvedCandidateNeedsTheNetwork() {
        let html = "<img src=\"\(a)\"><img src=\"\(b)\">"
        let out = rewrite(html, [a: dataA])
        XCTAssertTrue(out.html.contains(b))
        XCTAssertTrue(out.needsNetwork)
    }

    // MARK: srcset

    func testSrcsetIsDroppedWhenSrcIsCached() {
        let html = "<img srcset=\"\(b) 2x\" src=\"\(a)\" sizes=\"100vw\">"
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [a])
        let out = rewrite(html, [a: dataA])
        XCTAssertFalse(out.html.contains("srcset"))
        XCTAssertFalse(out.html.contains("sizes"))
        XCTAssertTrue(out.html.contains("src=\"\(dataA)\""))
        XCTAssertFalse(out.needsNetwork)
    }

    func testSrcsetIsKeptLiveWhenSrcIsNotCached() {
        let html = "<img srcset=\"\(b) 2x\" src=\"\(a)\">"
        let out = rewrite(html, [:])
        XCTAssertEqual(out.html, html)
        XCTAssertTrue(out.needsNetwork)
    }

    func testSrcsetOnlyUsesOneCandidate() {
        let c = "https://img.example.com/c.png"
        XCTAssertEqual(RemoteImageHTML.chooseSrcsetCandidate("\(a) 1x, \(b) 2x, \(c) 3x"), b)
        XCTAssertEqual(RemoteImageHTML.chooseSrcsetCandidate("\(a) 300w, \(b) 900w"), b)
        XCTAssertEqual(RemoteImageHTML.chooseSrcsetCandidate("\(a)"), a)
        let html = "<img srcset=\"\(a) 1x, \(b) 2x\" alt=x>"
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [b])
        let out = rewrite(html, [b: dataB])
        XCTAssertEqual(out.html, "<img src=\"\(dataB)\" alt=x>")
        XCTAssertFalse(out.needsNetwork)
    }

    // MARK: Not rewritten: stays live

    func testPositionsNotRewrittenStillNeedTheNetwork() {
        let cases = [
            "<picture><source srcset=\"\(a)\"><img src=\"data:image/png;base64,AA\"></picture>",
            "<video poster=\"\(a)\"></video>",
            "<input type=image src=\"\(a)\">",
            "<svg><image href=\"\(a)\"/></svg>",
            "<svg><image xlink:href=\"\(a)\"/></svg>",
            "<link rel=preload as=image href=\"\(a)\">",
            "<div style=\"background: image-set(url(\(a)) 1x)\"></div>",
            "<div style=\"background: url(\\68ttps://img.example.com/a.png)\"></div>",
            "<style>.x{background:u\\72l(\(a))}</style>",
        ]
        for html in cases {
            let out = rewrite(html, [a: dataA])
            XCTAssertTrue(out.needsNetwork, html)
        }
    }

    func testLinksAndNamespacesDoNotNeedTheNetwork() {
        let html = """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:v="urn:schemas-microsoft-com:vml">\
            <a href="https://shop.example.com/">Shop</a><area href="https://x.example.com/">\
            <blockquote cite="https://x.example.com/"></blockquote>\
            <meta itemprop="image" content="https://x.example.com/">\
            <p data-url="https://x.example.com/" title="https://x.example.com/">text https://x</p>
            """
        let out = rewrite(html, [:])
        XCTAssertEqual(out.urls, [])
        XCTAssertFalse(out.needsNetwork)
    }

    // MARK: Robustness

    func testCommentsScriptsAndRawTextAreSkipped() {
        let html = """
            <!-- <img src="\(a)"> --><script><img src="\(a)"></script>\
            <textarea><img src="\(a)"></textarea><title><img src="\(a)"></title><img src="\(b)">
            """
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [b])
    }

    func testMalformedHTMLDoesNotCrash() {
        let inputs = [
            "<img src=\"\(a)", "<img src=", "<", "<img", "<<<>>>", "<img src='\(a)' <img src=\(b)>",
            "<style>.x{background:url(\(a)", "<div style=\"background:url(", "</", "<!--",
            "<img src=\"\(a)\"\u{0}>", "<IMG SRC=\"\(a)\">", String(repeating: "<a ", count: 2_000),
            "<style>@font-face{", "<img srcset=\", , ,\">", "<td background=>",
        ]
        for html in inputs {
            let out = rewrite(html, [a: dataA, b: dataB])
            XCTAssertNotNil(out.html.utf8.count)
        }
        // Upper case tag and attribute names are found.
        XCTAssertEqual(RemoteImageHTML.candidates(in: "<IMG SRC=\"\(a)\">"), [a])
        // An unterminated tag is dropped by the HTML parser: not rewritten.
        XCTAssertEqual(rewrite("<p>x</p><img src=\"\(a)\"", [a: dataA]).html,
                       "<p>x</p><img src=\"\(a)\"")
    }

    func testDuplicateAttributesFollowTheParserFirstWins() {
        let html = "<img src=\"\(a)\" src=\"\(b)\">"
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [a])
    }

    func testNonASCIIContentSurvivesTheRewrite() {
        let html = "<p>Caffè — 日本語 🎉</p><img src=\"\(a)\"><p>fin</p>"
        let out = rewrite(html, [a: dataA])
        XCTAssertEqual(out.html, "<p>Caffè — 日本語 🎉</p><img src=\"\(dataA)\"><p>fin</p>")
    }

    /// The rewritten document still meets the CSP's terms: in the blocked
    /// variant nothing remote is left in a rewritten position, and only
    /// `data:` URLs were introduced.
    func testRewrittenDocumentKeepsTheCSPExpectations() {
        let html = "<img src=\"\(a)\"><td background=\"\(b)\"><div style=\"background:url(\(a))\">"
        let out = rewrite(html, [a: dataA, b: dataB])
        XCTAssertFalse(out.html.contains("https:"))
        XCTAssertFalse(out.needsNetwork)
        let doc = HTMLBodyDocument.assemble(
            html: out.html, cspMeta: HTMLBodyCSP.metaTag(allowRemoteImages: false),
            styleCSS: "")
        XCTAssertTrue(doc.contains("img-src data: cid:;"))
        XCTAssertEqual(RemoteImageHTML.candidates(in: out.html), [])
    }

    func testURLKeyIsTheSHA256OfTheURL() {
        XCTAssertEqual(RemoteImageHTML.urlKey("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertNotEqual(RemoteImageHTML.urlKey(a), RemoteImageHTML.urlKey(b))
    }
}
