import CryptoKit
import Foundation

/// Finds the remote (https) images of an HTML mail that the app can cache,
/// and rewrites them to `data:` URLs once their bytes are known.
///
/// Pure byte-level scanning (no WebKit, no regex over the whole body), so it
/// runs off the main actor on multi-megabyte bodies and unit tests can pin it.
///
/// What is rewritten (`candidates`, `rewrite`):
/// - `<img src>`. When it is rewritten, the image's `srcset` and `sizes` go
///   (Gmail does not honour `srcset` either), so the cached `src` is what
///   shows. An `<img>` with no `src` but a `srcset` uses one candidate: the
///   highest density up to 2x, else the widest.
/// - the `background` attribute of any element (`<body>`, `<table>`, `<td>`…).
/// - CSS `url()` in `style` attributes and `<style>` blocks, except inside
///   `@font-face` and `@import` (fonts and style sheets never load: the CSP
///   blocks them) and inside `image-set()`.
///
/// What is left alone, and keeps loading live from the web view when images
/// are allowed: `<picture><source srcset>`, `<video poster>`,
/// `<input type=image>`, SVG `<image>`/`<use>`/`<feImage>`, `<link>`,
/// `image-set()`, any URL in CSS written with a backslash escape, and every
/// URL the transport refuses. `data:`, `cid:` and `http:` URLs are never
/// touched (the CSP blocks `http:` in every variant).
///
/// `needsNetwork` on the result says whether anything in the rewritten
/// document could still make the web view fetch a remote image; when it is
/// false the document is shown with the blocked CSP, which is what lets a
/// neighbour pre-render (painted with the blocked CSP) be claimed by the
/// open. It errs towards true: any attribute holding an `https:` URL that is
/// not a known non-loading one (links, `xmlns`, `alt`…) counts.
enum RemoteImageHTML {
    struct Result: Equatable, Sendable {
        /// The rewritten document (the input when nothing was rewritten).
        var html: String
        /// Every candidate URL found, in document order, without repeats
        /// (normalised: what the web view would request).
        var urls: [String]
        /// How many candidate occurrences were rewritten.
        var rewrittenCount: Int
        /// Some remote image could still load from the network.
        var needsNetwork: Bool
    }

    /// The candidate URLs of `html` (see the type's documentation).
    static func candidates(in html: String) -> [String] {
        process(html, replacements: [:]).urls
    }

    /// Rewrites every candidate whose normalised URL has a `data:` URL in
    /// `dataURLs`; the rest stay as they are.
    static func rewrite(_ html: String, dataURLs: [String: String]) -> Result {
        process(html, replacements: dataURLs)
    }

    /// Lookup key of one URL: SHA-256 (hex) of the normalised URL string.
    static func urlKey(_ url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// What the web view would request for an attribute or CSS value: ASCII
    /// tab and newlines removed, surrounding whitespace trimmed. Nil unless
    /// the result is an absolute `https:` URL that `URL` parses.
    static func normalizedHTTPSURL(_ raw: String) -> String? {
        var s = raw.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }
        s = s.trimmingCharacters(in: .whitespaces.union(.controlCharacters))
        guard s.count > 8, s.prefix(8).lowercased() == "https://" else { return nil }
        s = "https://" + s.dropFirst(8)
        guard let url = URL(string: s), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url.absoluteString
    }

    // MARK: - Scanner

    private struct Edit {
        var range: Range<Int>
        var bytes: [UInt8]
    }

    private struct State {
        var urls: [String] = []
        var seen: Set<String> = []
        var edits: [Edit] = []
        var rewritten = 0
        var needsNetwork = false
        let replacements: [String: String]

        mutating func found(_ url: String) {
            if seen.insert(url).inserted { urls.append(url) }
        }
    }

    private struct Attribute {
        var name: String
        /// Whole attribute text, name through value.
        var whole: Range<Int>
        /// The value including its quotes; nil for a bare attribute.
        var valueWithQuotes: Range<Int>?
        /// The value without quotes.
        var value: Range<Int>?
    }

    private static let rawTextElements: Set<String> = [
        "script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes",
    ]

    private static func process(_ html: String, replacements: [String: String]) -> Result {
        let bytes = Array(html.utf8)
        var state = State(replacements: replacements)
        scanDocument(bytes, &state)
        guard !state.edits.isEmpty else {
            return Result(html: html, urls: state.urls, rewrittenCount: 0,
                          needsNetwork: state.needsNetwork)
        }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + state.edits.reduce(0) { $0 + $1.bytes.count })
        var cursor = 0
        for edit in state.edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard edit.range.lowerBound >= cursor else { continue }
            out.append(contentsOf: bytes[cursor..<edit.range.lowerBound])
            out.append(contentsOf: edit.bytes)
            cursor = edit.range.upperBound
        }
        out.append(contentsOf: bytes[cursor...])
        return Result(html: String(decoding: out, as: UTF8.self), urls: state.urls,
                      rewrittenCount: state.rewritten, needsNetwork: state.needsNetwork)
    }

    private static func scanDocument(_ b: [UInt8], _ state: inout State) {
        let n = b.count
        var i = 0
        while i < n {
            guard let lt = find(b, 0x3C, from: i) else { return }  // "<"
            i = lt
            guard i + 1 < n else { return }
            let next = b[i + 1]
            if next == 0x21 {  // "!"
                if i + 3 < n, b[i + 2] == 0x2D, b[i + 3] == 0x2D {  // "<!--"
                    guard let end = findSequence(b, Array("-->".utf8), from: i + 4) else { return }
                    i = end + 3
                } else {
                    guard let gt = find(b, 0x3E, from: i + 2) else { return }
                    i = gt + 1
                }
                continue
            }
            if next == 0x3F || next == 0x2F {  // "<?" or "</"
                guard let gt = find(b, 0x3E, from: i + 2) else { return }
                i = gt + 1
                continue
            }
            guard isASCIILetter(next) else {
                i += 1
                continue
            }
            guard let (name, attributes, end) = parseStartTag(b, at: i) else { return }
            handleTag(name, attributes, b, &state)
            i = end
            if rawTextElements.contains(name) {
                guard let close = findCloseTag(b, name: name, from: i) else {
                    if name == "style" { scanCSS(b, i..<n, inline: false, &state) }
                    return
                }
                if name == "style" { scanCSS(b, i..<close, inline: false, &state) }
                i = close
            } else if name == "plaintext" {
                return
            }
        }
    }

    /// Parses `<name attrs…>` starting at `start` ("<"). Nil when the tag
    /// never closes (the HTML parser drops it at end of file).
    private static func parseStartTag(_ b: [UInt8], at start: Int)
        -> (String, [Attribute], Int)? {
        let n = b.count
        var i = start + 1
        let nameStart = i
        while i < n, !isSpace(b[i]), b[i] != 0x2F, b[i] != 0x3E { i += 1 }
        let name = lowercased(b[nameStart..<i])
        var attributes: [Attribute] = []
        var names: Set<String> = []
        while i < n {
            while i < n, isSpace(b[i]) || b[i] == 0x2F { i += 1 }
            guard i < n else { return nil }
            if b[i] == 0x3E { return (name, attributes, i + 1) }
            let attrStart = i
            // An attribute name may begin with "=".
            i += 1
            while i < n, !isSpace(b[i]), b[i] != 0x2F, b[i] != 0x3E, b[i] != 0x3D { i += 1 }
            let attrName = lowercased(b[attrStart..<i])
            var j = i
            while j < n, isSpace(b[j]) { j += 1 }
            var valueWithQuotes: Range<Int>?
            var value: Range<Int>?
            if j < n, b[j] == 0x3D {  // "="
                j += 1
                while j < n, isSpace(b[j]) { j += 1 }
                guard j < n else { return nil }
                if b[j] == 0x22 || b[j] == 0x27 {
                    let quote = b[j]
                    guard let close = find(b, quote, from: j + 1) else { return nil }
                    value = (j + 1)..<close
                    valueWithQuotes = j..<(close + 1)
                    i = close + 1
                } else if b[j] == 0x3E {
                    value = j..<j
                    valueWithQuotes = j..<j
                    i = j
                } else {
                    var k = j
                    while k < n, !isSpace(b[k]), b[k] != 0x3E { k += 1 }
                    value = j..<k
                    valueWithQuotes = j..<k
                    i = k
                }
            }
            // Duplicate attributes: the first one wins, as in the parser.
            if names.insert(attrName).inserted {
                attributes.append(Attribute(name: attrName, whole: attrStart..<i,
                                            valueWithQuotes: valueWithQuotes, value: value))
            }
        }
        return nil
    }

    private static func handleTag(_ tag: String, _ attributes: [Attribute], _ b: [UInt8],
                                  _ state: inout State) {
        func decoded(_ attribute: Attribute?) -> String? {
            guard let range = attribute?.value else { return nil }
            return String(decoding: b[range], as: UTF8.self).decodingHTMLEntities()
        }
        let byName = Dictionary(attributes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        var handled: Set<String> = []
        if tag == "img" {
            handled.formUnion(["src", "srcset", "sizes"])
            handleImage(byName, decoded: decoded, &state)
        }
        if let background = byName["background"] {
            handled.insert("background")
            if let raw = decoded(background), let url = normalizedHTTPSURL(raw) {
                state.found(url)
                if let data = state.replacements[url], let range = background.valueWithQuotes {
                    state.edits.append(Edit(range: range, bytes: Array("\"\(data)\"".utf8)))
                    state.rewritten += 1
                } else {
                    state.needsNetwork = true
                }
            }
        }
        if let style = byName["style"], let raw = decoded(style) {
            handled.insert("style")
            let css = Array(raw.utf8)
            var inner = State(replacements: state.replacements)
            scanCSS(css, 0..<css.count, inline: true, &inner)
            for url in inner.urls { state.found(url) }
            state.needsNetwork = state.needsNetwork || inner.needsNetwork
            if !inner.edits.isEmpty, let range = style.valueWithQuotes {
                var rewritten: [UInt8] = []
                var cursor = 0
                for edit in inner.edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                    rewritten.append(contentsOf: css[cursor..<edit.range.lowerBound])
                    rewritten.append(contentsOf: edit.bytes)
                    cursor = edit.range.upperBound
                }
                rewritten.append(contentsOf: css[cursor...])
                let attr = encodeAttribute(String(decoding: rewritten, as: UTF8.self))
                state.edits.append(Edit(range: range, bytes: Array("\"\(attr)\"".utf8)))
                state.rewritten += inner.rewritten
            }
        }
        // Anything else holding an https URL may load an image: counted as
        // needing the network unless it is known never to load one.
        guard !state.needsNetwork else { return }
        for attribute in attributes where !handled.contains(attribute.name) {
            guard !neverLoads(attribute.name, tag: tag), let raw = decoded(attribute) else { continue }
            let squeezed = raw.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }.lowercased()
            if squeezed.contains("https:") {
                state.needsNetwork = true
                return
            }
        }
    }

    /// `<img>`: `src`, or the chosen `srcset` candidate when there is no
    /// `src`; a rewrite drops `srcset` and `sizes`.
    private static func handleImage(_ byName: [String: Attribute],
                                    decoded: (Attribute?) -> String?,
                                    _ state: inout State) {
        let src = byName["src"]
        let srcset = byName["srcset"]
        let srcsetHasRemote = decoded(srcset).map {
            $0.lowercased().contains("https:")
        } ?? false
        var url: String?
        var target: Attribute?
        if let src, let raw = decoded(src), !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            if let candidate = normalizedHTTPSURL(raw) {
                url = candidate
                target = src
            } else if srcsetHasRemote {
                // A data:/cid: src with a remote srcset: srcset wins on screen.
                state.needsNetwork = true
                return
            }
        } else if let raw = decoded(srcset), let chosen = chooseSrcsetCandidate(raw) {
            url = chosen
            target = srcset
        } else if srcsetHasRemote {
            state.needsNetwork = true
            return
        }
        guard let url, let target else { return }
        state.found(url)
        guard let data = state.replacements[url] else {
            state.needsNetwork = true
            return
        }
        if target.name == "src", let range = target.valueWithQuotes {
            state.edits.append(Edit(range: range, bytes: Array("\"\(data)\"".utf8)))
        } else {
            state.edits.append(Edit(range: target.whole, bytes: Array("src=\"\(data)\"".utf8)))
        }
        state.rewritten += 1
        for name in ["srcset", "sizes"] where name != target.name {
            if let attribute = byName[name] {
                state.edits.append(Edit(range: attribute.whole, bytes: []))
            }
        }
    }

    /// One `srcset` candidate: the highest density up to 2x (else the
    /// lowest), or with width descriptors the widest. Nil unless it is an
    /// https URL.
    static func chooseSrcsetCandidate(_ srcset: String) -> String? {
        var best: (url: String, density: Double?, width: Double?)?
        var options: [(url: String, density: Double?, width: Double?)] = []
        for part in splitSrcset(srcset) {
            guard let url = normalizedHTTPSURL(part.url) else { return nil }
            var density: Double? = 1
            var width: Double?
            for descriptor in part.descriptors {
                let d = descriptor.lowercased()
                if d.hasSuffix("x"), let value = Double(d.dropLast()) {
                    density = value
                } else if d.hasSuffix("w"), let value = Double(d.dropLast()) {
                    width = value
                    density = nil
                }
            }
            options.append((url, density, width))
        }
        guard !options.isEmpty else { return nil }
        let widths = options.filter { $0.width != nil }
        if !widths.isEmpty {
            best = widths.max { ($0.width ?? 0) < ($1.width ?? 0) }
        } else {
            let upTo2 = options.filter { ($0.density ?? 1) <= 2 }
            best = upTo2.max { ($0.density ?? 1) < ($1.density ?? 1) }
                ?? options.min { ($0.density ?? 1) < ($1.density ?? 1) }
        }
        return best?.url
    }

    private static func splitSrcset(_ s: String) -> [(url: String, descriptors: [String])] {
        var out: [(String, [String])] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace || chars[i] == "," { i += 1 }
            guard i < chars.count else { break }
            var url = ""
            while i < chars.count, !chars[i].isWhitespace { url.append(chars[i]); i += 1 }
            var descriptors: [String] = []
            if url.hasSuffix(",") {
                while url.hasSuffix(",") { url.removeLast() }
            } else {
                var current = ""
                var depth = 0
                while i < chars.count {
                    let c = chars[i]
                    if c == "(" { depth += 1 }
                    if c == ")" { depth = max(0, depth - 1) }
                    if c == ",", depth == 0 { i += 1; break }
                    if c.isWhitespace, depth == 0 {
                        if !current.isEmpty { descriptors.append(current); current = "" }
                    } else {
                        current.append(c)
                    }
                    i += 1
                }
                if !current.isEmpty { descriptors.append(current) }
            }
            if !url.isEmpty { out.append((url, descriptors)) }
        }
        return out
    }

    /// Attributes that hold URLs but never make the document load an image.
    private static func neverLoads(_ name: String, tag: String) -> Bool {
        if name.hasPrefix("data-") || name.hasPrefix("aria-") || name.hasPrefix("xmlns") {
            return true
        }
        switch name {
        case "href":
            return tag == "a" || tag == "area" || tag == "base"
        case "cite", "action", "formaction", "alt", "title", "value", "placeholder", "label",
             "content", "itemtype", "itemid", "itemprop", "longdesc", "summary", "id",
             "class", "name", "target", "rel", "type", "lang", "dir":
            return true
        default:
            return false
        }
    }

    // MARK: - CSS

    /// Scans CSS in `range` of `b`. Inline: `b` is a decoded `style`
    /// attribute (its edits are applied by the caller and re-encoded).
    private static func scanCSS(_ b: [UInt8], _ range: Range<Int>, inline: Bool,
                                _ state: inout State) {
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            let c = b[i]
            if c == 0x2F, i + 1 < end, b[i + 1] == 0x2A {  // "/*"
                i = (findSequence(b, Array("*/".utf8), from: i + 2, limit: end) ?? end - 2) + 2
                continue
            }
            if c == 0x22 || c == 0x27 {
                i = skipCSSString(b, from: i, end: end)
                continue
            }
            if c == 0x5C {  // "\": an escape could spell a URL we cannot see.
                state.needsNetwork = true
                i += 2
                continue
            }
            if c == 0x40 {  // "@"
                var k = i + 1
                while k < end, isIdentByte(b[k]) { k += 1 }
                let rule = lowercased(b[(i + 1)..<k])
                if rule == "font-face" {
                    i = skipBlock(b, from: k, end: end)
                } else if rule == "import" {
                    i = (find(b, 0x3B, from: k, limit: end) ?? end - 1) + 1
                } else {
                    i = k
                }
                continue
            }
            if isIdentStart(c), i == range.lowerBound || !isIdentByte(b[i - 1]) {
                var k = i
                while k < end, isIdentByte(b[k]) { k += 1 }
                if k < end, b[k] == 0x28 {  // "("
                    let fn = lowercased(b[i..<k])
                    if fn == "url" {
                        i = handleURLFunction(b, nameStart: i, open: k, end: end, &state)
                        continue
                    }
                    if fn == "image-set" || fn == "-webkit-image-set" {
                        let close = skipParens(b, from: k, end: end)
                        let body = String(decoding: b[k..<close], as: UTF8.self).lowercased()
                        if body.contains("https:") || body.contains("url(") {
                            state.needsNetwork = true
                        }
                        i = close
                        continue
                    }
                }
                i = max(k, i + 1)
                continue
            }
            i += 1
        }
    }

    /// `url(…)` at `nameStart`; returns the index after it.
    private static func handleURLFunction(_ b: [UInt8], nameStart: Int, open: Int, end: Int,
                                          _ state: inout State) -> Int {
        var i = open + 1
        while i < end, isSpace(b[i]) { i += 1 }
        guard i < end else { return end }
        var raw: String
        if b[i] == 0x22 || b[i] == 0x27 {
            let quote = b[i]
            var k = i + 1
            while k < end, b[k] != quote, b[k] != 0x5C, b[k] != 0x0A { k += 1 }
            guard k < end, b[k] == quote else {
                // Escaped or unterminated: leave it, count it as remote.
                state.needsNetwork = true
                return skipParens(b, from: open, end: end)
            }
            raw = String(decoding: b[(i + 1)..<k], as: UTF8.self)
            var j = k + 1
            while j < end, isSpace(b[j]) { j += 1 }
            guard j < end, b[j] == 0x29 else {
                state.needsNetwork = true
                return skipParens(b, from: open, end: end)
            }
            i = j + 1
        } else {
            var k = i
            while k < end, b[k] != 0x29, !isSpace(b[k]), b[k] != 0x22, b[k] != 0x27,
                  b[k] != 0x28, b[k] != 0x5C { k += 1 }
            var j = k
            while j < end, isSpace(b[j]) { j += 1 }
            guard j < end, b[j] == 0x29 else {
                state.needsNetwork = true
                return skipParens(b, from: open, end: end)
            }
            raw = String(decoding: b[i..<k], as: UTF8.self)
            i = j + 1
        }
        let lower = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if lower.hasPrefix("data:") || lower.hasPrefix("cid:") || lower.hasPrefix("#") {
            return i
        }
        guard let url = normalizedHTTPSURL(raw) else {
            if lower.filter({ $0 != "\t" && $0 != "\n" && $0 != "\r" }).hasPrefix("https:") {
                state.needsNetwork = true
            }
            return i
        }
        state.found(url)
        if let data = state.replacements[url] {
            state.edits.append(Edit(range: nameStart..<i, bytes: Array("url(\"\(data)\")".utf8)))
            state.rewritten += 1
        } else {
            state.needsNetwork = true
        }
        return i
    }

    private static func skipCSSString(_ b: [UInt8], from start: Int, end: Int) -> Int {
        let quote = b[start]
        var i = start + 1
        while i < end {
            if b[i] == 0x5C { i += 2; continue }
            if b[i] == quote || b[i] == 0x0A { return i + 1 }
            i += 1
        }
        return end
    }

    /// From an opening "(" to just after its matching ")".
    private static func skipParens(_ b: [UInt8], from open: Int, end: Int) -> Int {
        var depth = 0
        var i = open
        while i < end {
            let c = b[i]
            if c == 0x22 || c == 0x27 { i = skipCSSString(b, from: i, end: end); continue }
            if c == 0x28 { depth += 1 }
            if c == 0x29 {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return end
    }

    /// From after an at-rule's name to just after its block's "}".
    private static func skipBlock(_ b: [UInt8], from start: Int, end: Int) -> Int {
        var depth = 0
        var i = start
        while i < end {
            let c = b[i]
            if c == 0x22 || c == 0x27 { i = skipCSSString(b, from: i, end: end); continue }
            if c == 0x2F, i + 1 < end, b[i + 1] == 0x2A {
                i = (findSequence(b, Array("*/".utf8), from: i + 2, limit: end) ?? end - 2) + 2
                continue
            }
            if c == 0x7B { depth += 1 }
            if c == 0x7D {
                depth -= 1
                if depth <= 0 { return i + 1 }
            }
            if c == 0x3B, depth == 0 { return i + 1 }
            i += 1
        }
        return end
    }

    // MARK: - Bytes

    private static func encodeAttribute(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func find(_ b: [UInt8], _ byte: UInt8, from: Int, limit: Int? = nil) -> Int? {
        let end = limit ?? b.count
        var i = from
        while i < end {
            if b[i] == byte { return i }
            i += 1
        }
        return nil
    }

    private static func findSequence(_ b: [UInt8], _ seq: [UInt8], from: Int,
                                     limit: Int? = nil) -> Int? {
        let end = limit ?? b.count
        guard !seq.isEmpty, end - from >= seq.count else { return nil }
        var i = from
        while i + seq.count <= end {
            if b[i] == seq[0] {
                var match = true
                for k in 1..<seq.count where b[i + k] != seq[k] {
                    match = false
                    break
                }
                if match { return i }
            }
            i += 1
        }
        return nil
    }

    /// Start of the `</name` that ends a raw-text element, or nil.
    private static func findCloseTag(_ b: [UInt8], name: String, from: Int) -> Int? {
        let needle = Array(name.utf8)
        var i = from
        while let lt = find(b, 0x3C, from: i) {
            if lt + 1 + needle.count < b.count, b[lt + 1] == 0x2F {
                var match = true
                for k in 0..<needle.count where toLower(b[lt + 2 + k]) != needle[k] {
                    match = false
                    break
                }
                if match {
                    let after = lt + 2 + needle.count
                    if after >= b.count || isSpace(b[after]) || b[after] == 0x3E || b[after] == 0x2F {
                        return lt
                    }
                }
            }
            i = lt + 1
        }
        return nil
    }

    private static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D
    }

    private static func isASCIILetter(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    private static func isIdentStart(_ c: UInt8) -> Bool {
        isASCIILetter(c) || c == 0x2D || c == 0x5F
    }

    private static func isIdentByte(_ c: UInt8) -> Bool {
        isIdentStart(c) || (c >= 0x30 && c <= 0x39) || c >= 0x80
    }

    private static func toLower(_ c: UInt8) -> UInt8 {
        (c >= 0x41 && c <= 0x5A) ? c + 0x20 : c
    }

    private static func lowercased(_ s: ArraySlice<UInt8>) -> String {
        String(decoding: s.map(toLower), as: UTF8.self)
    }
}
