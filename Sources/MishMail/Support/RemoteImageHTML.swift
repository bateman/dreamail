import CryptoKit
import Foundation

/// Finds the remote (https) images of an HTML mail that the app can cache,
/// and rewrites them to `data:` URLs once their bytes are known.
///
/// Pure byte-level scanning (no WebKit, no regex over the whole body), so it
/// runs off the main actor on multi-megabyte bodies and unit tests can pin it.
///
/// What is rewritten (`candidates`, `rewrite`):
/// - `<img>`: with a usable `srcset`, one candidate (the highest density up
///   to 2x, else the widest) becomes the only one, as a `data:` URL with its
///   descriptor, and `src` goes; otherwise `src`.
/// - At most `outputBudget` bytes of `data:` URLs per document, whatever the
///   number of occurrences; the rest stay remote (and need the network).
/// - the `background` attribute of any element (`<body>`, `<table>`, `<td>`…).
/// - CSS `url()` in `style` attributes and `<style>` blocks, except inside
///   `@font-face` and `@import` (fonts and style sheets never load: the CSP
///   blocks them) and inside `image-set()`.
///
/// What is left alone, and keeps loading live from the web view when images
/// are allowed: an `<img>` `srcset` with a non-https candidate,
/// `<picture><source srcset>`, `<video poster>`,
/// `<input type=image>`, SVG `<image>`/`<use>`/`<feImage>`, `<link>`,
/// `image-set()`, any URL in CSS written with a backslash escape, and every
/// URL the transport refuses. `data:` and `cid:` URLs are never touched.
///
/// `http:` and protocol-relative (`//host/…`) image URLs count as the
/// `https:` URL they are upgraded to (`normalizedHTTPSURL`): Gmail shows
/// them (through its proxy), the CSP never admits `http:`, and the
/// document's base is `about:blank`, against which `//host/…` resolves to
/// nothing. `upgradingInsecureImageURLs` gives `//` URLs the `https:`
/// scheme in the document the web view loads with remote images allowed;
/// `upgrade-insecure-requests` in that CSP upgrades every `http:` request
/// (redirects to `http:` included).
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
        process(html, replacements: [:], budget: 0).urls
    }

    /// Rewrites every candidate whose normalised URL has a `data:` URL in
    /// `dataURLs`; the rest stay as they are.
    static func rewrite(_ html: String, dataURLs: [String: String],
                        budget: Int = outputBudget) -> Result {
        process(html, replacements: dataURLs, budget: budget)
    }

    /// Lookup key of one URL: SHA-256 (hex) of the normalised URL string.
    static func urlKey(_ url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// What the web view would request for an attribute or CSS value: ASCII
    /// tab and newlines removed, surrounding whitespace trimmed. Nil unless
    /// the result is an absolute `https:` URL that `URL` parses.
    ///
    /// An `http:` or protocol-relative URL is normalised to the `https:` URL
    /// it is upgraded to (port 80 dropped, as `upgrade-insecure-requests`
    /// does).
    static func normalizedHTTPSURL(_ raw: String) -> String? {
        var s = raw.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }
        s = s.trimmingCharacters(in: .whitespaces.union(.controlCharacters))
        var upgraded = false
        if s.hasPrefix("//") {
            s = "https:" + s
            upgraded = true
        } else if s.prefix(7).lowercased() == "http://" {
            s = "https://" + s.dropFirst(7)
            upgraded = true
        }
        guard s.count > 8, s.prefix(8).lowercased() == "https://" else { return nil }
        s = "https://" + s.dropFirst(8)
        guard var url = URL(string: s), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        if upgraded, url.port == 80,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.port = nil
            if let withoutPort = components.url { url = withoutPort }
        }
        return url.absoluteString
    }

    /// `html` with every protocol-relative (`//host/…`) image URL the
    /// scanner sees (`<img src/srcset>`, `<picture><source srcset>`,
    /// `background`, CSS `url()` in `style` attributes and `<style>`) given
    /// the `https:` scheme: against the `about:blank` base it would resolve
    /// to nothing. Only `https:` is inserted in front; nothing else in the
    /// value is touched, so no value can grow past its quotes. `http:` URLs
    /// are left to `upgrade-insecure-requests` in the allowed CSP, which
    /// also drops port 80 as `normalizedHTTPSURL` does. Links, `xmlns` and
    /// every other attribute stay as they are. Returns `html` itself when
    /// there is nothing to change.
    static func upgradingInsecureImageURLs(in html: String) -> String {
        let bytes = Array(html.utf8)
        guard mayHaveProtocolRelativeURL(bytes) else { return html }
        var state = State(replacements: [:], budget: 0, upgrade: true)
        scanDocument(bytes, &state)
        guard !state.edits.isEmpty else { return html }
        return String(decoding: applying(state.edits, to: bytes), as: UTF8.self)
    }

    /// Cheap pre-check: `//` right after a quote, `=`, `(`, `,`, `;` (an
    /// entity-encoded quote) or a space, where a protocol-relative URL can
    /// start. Most mail has none, and is then not scanned at all.
    private static func mayHaveProtocolRelativeURL(_ b: [UInt8]) -> Bool {
        let n = b.count
        var i = 1
        while i + 1 < n {
            if b[i] == 0x2F, b[i + 1] == 0x2F {
                let p = b[i - 1]
                if p == 0x22 || p == 0x27 || p == 0x3D || p == 0x28 || p == 0x2C || p == 0x3B
                    || isSpace(p) {
                    return true
                }
            }
            i += 1
        }
        return false
    }

    /// The edit that gives the URL starting at the first non-space byte of
    /// `range` the `https:` scheme, if it is protocol-relative (`//`).
    private static func upgradeEdit(_ b: [UInt8], _ range: Range<Int>) -> Edit? {
        var i = range.lowerBound
        while i < range.upperBound, isSpace(b[i]) { i += 1 }
        let left = range.upperBound - i
        if left >= 2, b[i] == 0x2F, b[i + 1] == 0x2F {
            return Edit(range: i..<i, bytes: Array("https:".utf8))
        }
        return nil
    }

    /// Upgrade edits for every candidate URL of a `srcset` value at `range`.
    private static func srcsetUpgradeEdits(_ b: [UInt8], _ range: Range<Int>) -> [Edit] {
        var edits: [Edit] = []
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            while i < end, isSpace(b[i]) || b[i] == 0x2C { i += 1 }
            guard i < end else { break }
            let start = i
            while i < end, !isSpace(b[i]) { i += 1 }
            if let edit = upgradeEdit(b, start..<i) { edits.append(edit) }
            if b[i - 1] == 0x2C { continue }
            // Descriptors, up to the next top-level comma.
            var depth = 0
            while i < end {
                let c = b[i]
                if c == 0x28 { depth += 1 }
                if c == 0x29 { depth = max(0, depth - 1) }
                i += 1
                if c == 0x2C, depth == 0 { break }
            }
        }
        return edits
    }

    private static func applying(_ edits: [Edit], to bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + edits.reduce(0) { $0 + $1.bytes.count })
        var cursor = 0
        for edit in edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard edit.range.lowerBound >= cursor else { continue }
            out.append(contentsOf: bytes[cursor..<edit.range.lowerBound])
            out.append(contentsOf: edit.bytes)
            cursor = edit.range.upperBound
        }
        out.append(contentsOf: bytes[cursor...])
        return out
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
        /// Bytes of `data:` URLs this document may still take in. Caps
        /// the rewritten size whatever the number of occurrences: one cached
        /// image referenced ten thousand times is inlined only while it fits.
        var budget: Int
        /// `upgradingInsecureImageURLs`: record `//` → `https://`, no data.
        var upgrade = false

        mutating func found(_ url: String) {
            if seen.insert(url).inserted { urls.append(url) }
        }

        /// The `data:` URL to write for one occurrence of `url`, charged to
        /// the budget; nil (and the occurrence needs the network) when there
        /// is none or it no longer fits.
        mutating func take(_ url: String) -> String? {
            guard let data = replacements[url], data.utf8.count <= budget else {
                needsNetwork = true
                return nil
            }
            budget -= data.utf8.count
            return data
        }
    }

    /// Most bytes of `data:` URLs one rewrite adds: base64 of the per-message
    /// image cap, plus slack for a few repeated small images.
    static let outputBudget = RemoteImageFetchPolicy.maxMessageBytes / 3 * 4 + 256 * 1_024

    /// Attribute values longer than this that are already `data:` URLs are
    /// skipped without decoding (an inlined image is never a candidate).
    private static let longValueBytes = 4_096

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

    private static func process(_ html: String, replacements: [String: String],
                                budget: Int) -> Result {
        let bytes = Array(html.utf8)
        var state = State(replacements: replacements, budget: budget)
        scanDocument(bytes, &state)
        guard !state.edits.isEmpty else {
            return Result(html: html, urls: state.urls, rewrittenCount: 0,
                          needsNetwork: state.needsNetwork)
        }
        let out = applying(state.edits, to: bytes)
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
            if range.count > longValueBytes, isDataURL(b, range) { return nil }
            return String(decoding: b[range], as: UTF8.self).decodingHTMLEntities()
        }
        let byName = Dictionary(attributes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        var handled: Set<String> = []
        if state.upgrade {
            if tag == "img", let range = byName["src"]?.value, let edit = upgradeEdit(b, range) {
                state.edits.append(edit)
            }
            if tag == "img" || tag == "source", let range = byName["srcset"]?.value {
                state.edits += srcsetUpgradeEdits(b, range)
            }
            if let range = byName["background"]?.value, let edit = upgradeEdit(b, range) {
                state.edits.append(edit)
            }
        }
        if tag == "img" {
            handled.formUnion(["src", "srcset", "sizes"])
            handleImage(byName, decoded: decoded, &state)
        }
        if tag == "link" {
            // Style sheets and microdata links never load under the CSP;
            // only preloads, prefetches and icons can fetch an image.
            let rel = (decoded(byName["rel"]) ?? "").lowercased()
            let fetches = ["preload", "prefetch", "prerender", "icon"].contains { rel.contains($0) }
            if !fetches { handled.insert("href") }
        }
        if let background = byName["background"] {
            handled.insert("background")
            if let raw = decoded(background) {
                if let url = normalizedHTTPSURL(raw) {
                    state.found(url)
                    if let range = background.valueWithQuotes, let data = state.take(url) {
                        state.edits.append(Edit(range: range, bytes: Array("\"\(data)\"".utf8)))
                        state.rewritten += 1
                    } else {
                        state.needsNetwork = true
                    }
                } else if looksRemote(raw) {
                    state.needsNetwork = true
                }
            }
        }
        if state.upgrade, let style = byName["style"] {
            // Never re-serialised here: the CSS is scanned over the
            // document's own bytes and only `https:` is inserted, at document
            // offsets. A value with an entity is left as it is (its bytes
            // are not the CSS WebKit reads).
            handled.insert("style")
            if let range = style.value, !b[range].contains(0x26) {  // "&"
                var inner = State(replacements: [:], budget: 0, upgrade: true)
                scanCSS(b, range, inline: true, &inner)
                state.edits += inner.edits
            }
        } else if let style = byName["style"], let raw = decoded(style) {
            handled.insert("style")
            let css = Array(raw.utf8)
            var inner = State(replacements: state.replacements, budget: state.budget)
            scanCSS(css, 0..<css.count, inline: true, &inner)
            for url in inner.urls { state.found(url) }
            state.budget = inner.budget
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
            // `//host/…` in an image position is upgraded to https before
            // loading (`<picture><source srcset>`, `<video poster>`…).
            let imagePosition = ["src", "srcset", "poster"].contains(attribute.name)
            if squeezed.contains("https:") || squeezed.contains("http:")
                || (imagePosition && squeezed.contains("//")) {
                state.needsNetwork = true
                return
            }
        }
    }

    /// `<img>`: a usable `srcset` wins (it is what WebKit shows): its chosen
    /// candidate becomes the only one, `srcset="data:… 2x"` with its own
    /// descriptor (so Retina sharpness and intrinsic size are kept), and
    /// `src` goes; `sizes` stays for a width descriptor. Without a usable
    /// `srcset`, `src`.
    private static func handleImage(_ byName: [String: Attribute],
                                    decoded: (Attribute?) -> String?,
                                    _ state: inout State) {
        let src = byName["src"]
        let srcset = byName["srcset"]
        let srcsetRaw = decoded(srcset)
        if let srcset, let raw = srcsetRaw, let chosen = chooseSrcsetCandidate(raw) {
            state.found(chosen.url)
            guard let range = srcset.valueWithQuotes, let data = state.take(chosen.url) else {
                state.needsNetwork = true
                return
            }
            state.edits.append(Edit(range: range,
                                    bytes: Array("\"\(data) \(chosen.descriptor)\"".utf8)))
            state.rewritten += 1
            if let src { state.edits.append(Edit(range: src.whole, bytes: [])) }
            if chosen.descriptor.hasSuffix("x"), let sizes = byName["sizes"] {
                state.edits.append(Edit(range: sizes.whole, bytes: []))
            }
            return
        }
        if let raw = srcsetRaw, looksRemote(raw) || raw.lowercased().contains("https:")
            || raw.lowercased().contains("http:") {
            // A srcset the app cannot use: WebKit loads it live.
            state.needsNetwork = true
            return
        }
        guard let src, let raw = decoded(src) else { return }
        guard let url = normalizedHTTPSURL(raw) else {
            if looksRemote(raw) { state.needsNetwork = true }
            return
        }
        state.found(url)
        guard let range = src.valueWithQuotes, let data = state.take(url) else {
            state.needsNetwork = true
            return
        }
        state.edits.append(Edit(range: range, bytes: Array("\"\(data)\"".utf8)))
        state.rewritten += 1
    }

    /// One `srcset` candidate and its descriptor (`2x`, `900w`): the highest
    /// density up to 2x (else the lowest), or with width descriptors the
    /// widest. Nil unless every candidate is an https URL.
    static func chooseSrcsetCandidate(_ srcset: String) -> (url: String, descriptor: String)? {
        var options: [(url: String, density: Double?, width: Double?)] = []
        for part in splitSrcset(srcset) {
            guard let url = normalizedHTTPSURL(part.url) else { return nil }
            var density: Double? = 1
            var width: Double?
            for descriptor in part.descriptors {
                let d = descriptor.lowercased()
                if d.hasSuffix("x"), let value = Double(d.dropLast()), value > 0 {
                    density = value
                } else if d.hasSuffix("w"), let value = Double(d.dropLast()), value > 0 {
                    width = value
                    density = nil
                }
            }
            options.append((url, density, width))
        }
        guard !options.isEmpty else { return nil }
        let widths = options.filter { $0.width != nil }
        if let best = widths.max(by: { ($0.width ?? 0) < ($1.width ?? 0) }), let width = best.width {
            return (best.url, "\(Int(width))w")
        }
        let upTo2 = options.filter { ($0.density ?? 1) <= 2 }
        guard let best = upTo2.max(by: { ($0.density ?? 1) < ($1.density ?? 1) })
                ?? options.min(by: { ($0.density ?? 1) < ($1.density ?? 1) }) else { return nil }
        let density = best.density ?? 1
        let text = density == density.rounded() ? String(Int(density)) : String(density)
        return (best.url, text + "x")
    }

    /// What the web view would still treat as a remote URL although `URL`
    /// does not parse it (`https:/host`, `https:host`, backslashes…).
    /// `http:` and `//` too: they are upgraded to https before loading.
    private static func looksRemote(_ raw: String) -> Bool {
        let s = raw.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }
            .trimmingCharacters(in: .whitespaces.union(.controlCharacters))
            .lowercased()
        return s.hasPrefix("https:") || s.hasPrefix("http:") || s.hasPrefix("//")
    }

    /// Whether the value at `range` starts (after spaces) with `data:`.
    private static func isDataURL(_ b: [UInt8], _ range: Range<Int>) -> Bool {
        var i = range.lowerBound
        while i < range.upperBound, isSpace(b[i]) { i += 1 }
        let prefix = Array("data:".utf8)
        guard range.upperBound - i >= prefix.count else { return false }
        for k in 0..<prefix.count where toLower(b[i + k]) != prefix[k] { return false }
        return true
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

    /// Scans CSS in `range` of `b`. Inline: a `style` attribute, either
    /// decoded (`rewrite`: its edits are applied by the caller and
    /// re-encoded) or, for `upgradingInsecureImageURLs`, the document's own
    /// bytes of the value (edits at document offsets, never re-encoded).
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
        let rawStart = (b[i] == 0x22 || b[i] == 0x27) ? i + 1 : i
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
        if state.upgrade, let edit = upgradeEdit(b, rawStart..<(rawStart + raw.utf8.count)) {
            state.edits.append(edit)
        }
        guard let url = normalizedHTTPSURL(raw) else {
            if looksRemote(lower) { state.needsNetwork = true }
            return i
        }
        state.found(url)
        if let data = state.take(url) {
            state.edits.append(Edit(range: nameStart..<i, bytes: Array("url(\"\(data)\")".utf8)))
            state.rewritten += 1
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
