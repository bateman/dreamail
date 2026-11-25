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

    func testDataCidAndRelativeURLsAreLeftAlone() {
        let html = """
            <img src="data:image/png;base64,AAAA"><img src="cid:logo@x"><img src="/rel.png">\
            <div style="background:url(data:image/gif;base64,R0)"></div>
            """
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [])
        let out = rewrite(html, [:])
        XCTAssertEqual(out.html, html)
        XCTAssertFalse(out.needsNetwork)
        XCTAssertEqual(RemoteImageHTML.upgradingInsecureImageURLs(in: html), html)
    }

    // MARK: http and protocol-relative images (upgraded to https)

    /// Gmail shows `http:` and `//host/…` images; the app's CSP admits only
    /// `https:` and its document base is `about:blank`. Both count as the
    /// https URL they are upgraded to: cached, and needing the network until
    /// they are.
    func testHTTPAndProtocolRelativeImagesCountAsTheirHTTPSURL() {
        let html = """
            <img src="http://img.example.com/clear.png"><img src="//img.example.com/proto.png">\
            <img src="HTTP://img.example.com:80/port.png">
            """
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [
            "https://img.example.com/clear.png", "https://img.example.com/proto.png",
            "https://img.example.com/port.png",
        ])
        XCTAssertTrue(rewrite(html, [:]).needsNetwork, "they load once upgraded")
        let cached = rewrite(html, [
            "https://img.example.com/clear.png": dataA, "https://img.example.com/proto.png": dataB,
            "https://img.example.com/port.png": dataA,
        ])
        XCTAssertEqual(cached.html, "<img src=\"\(dataA)\"><img src=\"\(dataB)\"><img src=\"\(dataA)\">")
        XCTAssertFalse(cached.needsNetwork)
        XCTAssertEqual(RemoteImageHTML.normalizedHTTPSURL("http://img.example.com:8080/a.png"),
                       "https://img.example.com:8080/a.png", "another port is kept")
    }

    /// The rewrite gives protocol-relative image URLs the https scheme, in
    /// every position the scanner knows, and nothing else: `http:` URLs
    /// (left to `upgrade-insecure-requests`), links, namespaces, text and
    /// https URLs are untouched.
    func testUpgradeGivesProtocolRelativeImageURLsHTTPSOnly() {
        let html = """
            <html xmlns="http://www.w3.org/1999/xhtml"><a href="//shop.example.com/">\
            <img src=" //img.example.com/logo.png" alt="Logo: //x"></a>\
            <img src='//img.example.com/a.png'><img src=//img.example.com/b.png>\
            <img src="http://img.example.com:80/h.png">\
            <img srcset="http://img.example.com/1.png 1x, //img.example.com/2.png 2x" src="\(a)">\
            <picture><source srcset="//img.example.com/w.webp"><img src="\(b)"></picture>\
            <table background="//img.example.com/bg.jpg"><tr>\
            <td style="background-image:url('//img.example.com/td.png');color:red">x</td>\
            <td style="background:url(&quot;//img.example.com/q.png&quot;)">y</td></tr></table>\
            <style>.h{background:url(//img.example.com/s.png)} .k{background:url("//img.example.com/k.png")}</style>\
            <p>see http://example.com and //comment</p>
            """
        let out = RemoteImageHTML.upgradingInsecureImageURLs(in: html)
        let expected = """
            <html xmlns="http://www.w3.org/1999/xhtml"><a href="//shop.example.com/">\
            <img src=" https://img.example.com/logo.png" alt="Logo: //x"></a>\
            <img src='https://img.example.com/a.png'><img src=https://img.example.com/b.png>\
            <img src="http://img.example.com:80/h.png">\
            <img srcset="http://img.example.com/1.png 1x, https://img.example.com/2.png 2x" src="\(a)">\
            <picture><source srcset="https://img.example.com/w.webp"><img src="\(b)"></picture>\
            <table background="https://img.example.com/bg.jpg"><tr>\
            <td style="background-image:url('https://img.example.com/td.png');color:red">x</td>\
            <td style="background:url(&quot;//img.example.com/q.png&quot;)">y</td></tr></table>\
            <style>.h{background:url(https://img.example.com/s.png)} .k{background:url("https://img.example.com/k.png")}</style>\
            <p>see http://example.com and //comment</p>
            """
        XCTAssertEqual(out, expected)
        XCTAssertEqual(RemoteImageHTML.upgradingInsecureImageURLs(in: out), out, "idempotent")
        let plain = "<img src=\"\(a)\"><a href=\"http://x.example.com/\">x</a>"
        XCTAssertEqual(RemoteImageHTML.upgradingInsecureImageURLs(in: plain), plain)
    }

    /// Where the scanner and WebKit disagree on markup (an SVG `<title>` is
    /// raw text to the scanner, markup to WebKit), the rewrite still only
    /// inserts `https:` before `//`: no attribute is re-serialised, no quote
    /// is added or changed.
    func testUpgradeOnlyEverInsertsTheScheme() {
        let svgTitle = """
            <svg><title><a href="https://a.example/" title="</title>\
            <i style='background:url(//x.example/a);X'>">t</a></title></svg>
            """
        let out = RemoteImageHTML.upgradingInsecureImageURLs(in: svgTitle)
        XCTAssertEqual(out, svgTitle.replacingOccurrences(of: "url(//x.example", with: "url(https://x.example"))

        let hostile = [
            svgTitle,
            "<div style=\"background:url(//a.example/x)\" title='\"><img src=//b.example/y>'>",
            "<td style='color:red;background:url(\"//a.example/q\")'>",
            "<td style=\"background:url(&quot;//a.example/q&quot;)\">",
            "<td style=background:url(//a.example/u)>x",
            "<img src=\"//a.example/1\" srcset=\"//a.example/2 2x,//a.example/3 3x\" style=\"x:url(//a.example/4)\">",
            "<style>a{background:url(//a.example/s)}</style><textarea><img src=//a.example/t></textarea>",
            "<img src='//a.example/\"onerror=x'><img src=\"//a.example/'>\">",
            "<!-- <img src=//a.example/c> --><img src=\" \n//a.example/n\">",
            "<img src=//a.example/x <img src=//a.example/y>",
        ]
        for html in hostile {
            let upgraded = RemoteImageHTML.upgradingInsecureImageURLs(in: html)
            XCTAssertEqual(upgraded.utf8.count - html.utf8.count, 6 * (upgraded.components(separatedBy: "https://").count
                                                                       - html.components(separatedBy: "https://").count),
                           "only `https:` inserted: \(upgraded)")
            XCTAssertEqual(upgraded.replacingOccurrences(of: "https://", with: "//"),
                           html.replacingOccurrences(of: "https://", with: "//"),
                           "reversing the inserted scheme gives the input back: \(upgraded)")
        }
        // An entity-encoded style value is left alone (the CSP upgrades
        // what it can; `//` there stays unresolved rather than re-serialised).
        let entity = "<td style=\"background:url(&quot;//a.example/q&quot;)\">"
        XCTAssertEqual(RemoteImageHTML.upgradingInsecureImageURLs(in: entity), entity)
    }

    /// Only the allowed variant is rewritten; the blocked one loads no
    /// remote image and is assembled as before.
    func testAllowedDocumentIsAssembledWithUpgradedImageURLs() {
        let html = "<img src=\"http://img.example.com/a.png\"><img src=\"//img.example.com/b.png\">"
        let allowed = HTMLBodyDocument.assemble(
            html: html, cspMeta: HTMLBodyCSP.metaTag(allowRemoteImages: true), styleCSS: "")
        XCTAssertTrue(allowed.contains("<img src=\"http://img.example.com/a.png\"><img src=\"https://img.example.com/b.png\">"),
                      "http: is left to upgrade-insecure-requests: \(allowed)")
        let blocked = HTMLBodyDocument.assemble(
            html: html, cspMeta: HTMLBodyCSP.metaTag(allowRemoteImages: false), styleCSS: "")
        XCTAssertTrue(blocked.hasSuffix("<body>\(html)</body></html>"))
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

    func testSrcsetCandidateWinsKeepsItsDensityAndDropsSrc() {
        let html = "<img srcset=\"\(a) 1x, \(b) 2x\" src=\"\(a)\" sizes=\"100vw\">"
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [b], "what WebKit shows on Retina")
        let out = rewrite(html, [b: dataB])
        XCTAssertTrue(out.html.contains("srcset=\"\(dataB) 2x\""), out.html)
        XCTAssertFalse(out.html.contains("src=\"\(a)"), "src goes")
        XCTAssertFalse(out.html.contains("sizes"), "sizes is meaningless with a density")
        XCTAssertFalse(out.needsNetwork)
    }

    func testWidthDescriptorKeepsSizes() {
        let html = "<img srcset=\"\(a) 300w, \(b) 900w\" sizes=\"50vw\">"
        let out = rewrite(html, [b: dataB])
        XCTAssertTrue(out.html.contains("srcset=\"\(dataB) 900w\""), out.html)
        XCTAssertTrue(out.html.contains("sizes=\"50vw\""))
        XCTAssertFalse(out.needsNetwork)
    }

    func testUncachedSrcsetStaysLive() {
        let html = "<img srcset=\"\(b) 2x\" src=\"\(a)\">"
        let out = rewrite(html, [a: dataA])
        XCTAssertEqual(out.html, html, "the srcset candidate is what shows: nothing to rewrite")
        XCTAssertTrue(out.needsNetwork)
    }

    func testMixedSrcsetIsUsableOnceUpgraded() {
        let html = "<img srcset=\"http://x.example.com/1.png 1x, \(b) 2x\" src=\"\(a)\">"
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [b])
        XCTAssertTrue(rewrite(html, [a: dataA]).needsNetwork)
    }

    func testSrcsetWithAnUnusableCandidateIsLeftLive() {
        let html = "<img srcset=\"/rel/1.png 1x, \(b) 2x\" src=\"\(a)\">"
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [])
        XCTAssertTrue(rewrite(html, [a: dataA]).needsNetwork)
    }

    func testSrcsetChoice() {
        let c = "https://img.example.com/c.png"
        let x = RemoteImageHTML.chooseSrcsetCandidate("\(a) 1x, \(b) 2x, \(c) 3x")
        XCTAssertEqual(x?.url, b)
        XCTAssertEqual(x?.descriptor, "2x")
        let w = RemoteImageHTML.chooseSrcsetCandidate("\(a) 300w, \(b) 900w")
        XCTAssertEqual(w?.url, b)
        XCTAssertEqual(w?.descriptor, "900w")
        XCTAssertEqual(RemoteImageHTML.chooseSrcsetCandidate("\(a)")?.descriptor, "1x")
        XCTAssertEqual(RemoteImageHTML.chooseSrcsetCandidate("\(a) 1.5x")?.descriptor, "1.5x")
        let only = "<img srcset=\"\(a) 1x, \(b) 2x\" alt=x>"
        XCTAssertEqual(rewrite(only, [b: dataB]).html, "<img srcset=\"\(dataB) 2x\" alt=x>")
    }

    // MARK: Output budget

    /// One cached image referenced ten thousand times: the rewrite stays
    /// within its budget; the occurrences past it stay remote.
    func testRepeatedReferencesCannotInflateTheDocument() {
        let big = "data:image/png;base64," + String(repeating: "A", count: 1_000_000)
        let html = String(repeating: "<img src=\"\(a)\">", count: 10_000)
        let out = rewrite(html, [a: big])
        XCTAssertLessThanOrEqual(out.html.utf8.count, html.utf8.count + RemoteImageHTML.outputBudget)
        XCTAssertGreaterThan(out.rewrittenCount, 0)
        XCTAssertLessThan(out.rewrittenCount, 10_000)
        XCTAssertTrue(out.needsNetwork, "the rest load live")
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [a])
        // Same through CSS, inline and in a block.
        let css = String(repeating: "<div style=\"background:url(\(a))\"></div>", count: 10_000)
            + "<style>" + String(repeating: ".x{background:url(\(a))}", count: 10_000) + "</style>"
        let cssOut = rewrite(css, [a: big])
        XCTAssertLessThanOrEqual(cssOut.html.utf8.count, css.utf8.count + RemoteImageHTML.outputBudget)
        XCTAssertTrue(cssOut.needsNetwork)
    }

    func testTheBudgetCoversTheMessageCap() {
        XCTAssertGreaterThanOrEqual(RemoteImageHTML.outputBudget,
                                    RemoteImageFetchPolicy.maxMessageBytes / 3 * 4)
        XCTAssertLessThanOrEqual(RemoteImageFetchPolicy.maxMessageBytes / 3 * 4 + 256 * 1_024,
                                 CIDInlineCachePolicy.maximumBytes,
                                 "a message's cached images fit the in-memory body cap")
    }

    // MARK: URLs the app cannot parse

    func testUnparsableHTTPSURLsStillNeedTheNetwork() {
        for raw in ["https:/img.example.com/a.png", "https:img.example.com/a.png",
                    "https:\\\\img.example.com\\a.png", " HTTPS:/x"] {
            for html in ["<img src=\"\(raw)\">", "<td background=\"\(raw)\">"] {
                let out = rewrite(html, [:])
                XCTAssertTrue(out.needsNetwork, html)
            }
        }
    }

    // MARK: link

    func testStyleSheetAndMicrodataLinksDoNotNeedTheNetwork() {
        for html in ["<link rel=\"stylesheet\" href=\"https://css.example.com/s.css\">",
                     "<link itemprop=\"url\" href=\"https://x.example.com/\">",
                     "<link rel=canonical href=https://x.example.com/>"] {
            XCTAssertFalse(rewrite(html, [:]).needsNetwork, html)
        }
        for html in ["<link rel=preload as=image href=\"\(a)\">",
                     "<link rel=\"shortcut icon\" href=\"\(a)\">",
                     "<link rel=prefetch href=\"\(a)\">"] {
            XCTAssertTrue(rewrite(html, [:]).needsNetwork, html)
        }
    }

    func testLongDataURLValuesAreSkipped() {
        let long = "data:image/png;base64," + String(repeating: "Q", count: 20_000)
        let html = "<img src=\"\(long)\"><img src=\"\(a)\">"
        XCTAssertEqual(RemoteImageHTML.candidates(in: html), [a])
        let out = rewrite(html, [a: dataA])
        XCTAssertTrue(out.html.hasPrefix("<img src=\"\(long)\">"))
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
