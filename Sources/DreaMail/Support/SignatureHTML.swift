import Foundation

/// The look of a Gmail signature, kept: Gmail's HTML (untrusted input)
/// rebuilt from an allow-list, so what is sent looks as it does in Gmail.
///
/// The HTML is parsed into a tree (Foundation's HTML tidy parser), then
/// written out again keeping only:
/// - layout and text elements (div, span, p, br, b, strong, i, em, u, font,
///   a, tables, lists, headings, small, sub, sup, center, hr);
/// - presentation attributes (`color`, `face`, `size`, `bgcolor`, `width`,
///   `height`, `align`, `valign`, `border`, `cellpadding`, `cellspacing`,
///   `colspan`, `rowspan`, `dir`) with plain values;
/// - inline `style` declarations from `allowedProperties`, with values made
///   of plain words, numbers, lengths, quoted font names and colour
///   functions only;
/// - links to http, https and mailto (`ComposeLinks.normalizeURL`), unless
///   the link text names another address.
///
/// Everything else goes: scripts, styles, `<link>`, frames, forms, images
/// (counted: nothing remote is fetched, at render or by the recipient's
/// client from what DreaMail sends), event handlers, classes and ids, and
/// any style with `url(`, `expression`, `position`, escapes, or a negative
/// margin (which could pull it over the text around it). Text is escaped.
enum SignatureHTML {
    struct Result: Equatable {
        var html: String
    }

    static let allowedElements: Set<String> = [
        "div", "span", "p", "br", "hr", "b", "strong", "i", "em", "u", "s", "strike",
        "font", "a", "small", "big", "sub", "sup", "center",
        "table", "thead", "tbody", "tfoot", "tr", "td", "th",
        "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote",
    ]

    /// Dropped with their content.
    static let droppedWhole: Set<String> = [
        "script", "style", "head", "title", "noscript", "template", "form", "textarea",
        "select", "button", "object", "embed", "iframe", "frame", "frameset", "svg",
        "math", "link", "meta", "input", "base", "audio", "video", "canvas", "applet",
    ]

    static let voidElements: Set<String> = ["br", "hr"]

    /// Deeper nesting is refused: no real signature comes near it, and the
    /// parser and `write` recurse once per level.
    static let maxDepth = 64

    /// Elements that may carry a `height` attribute.
    static let heightElements: Set<String> = ["table", "tr", "td", "th"]

    static let allowedAttributes: Set<String> = [
        "style", "dir", "align", "valign", "width", "height", "bgcolor", "color", "face",
        "size", "border", "cellpadding", "cellspacing", "colspan", "rowspan",
    ]

    static let allowedProperties: Set<String> = [
        "color", "background-color",
        "font-family", "font-size", "font-weight", "font-style", "font-variant",
        "text-decoration", "text-decoration-line", "text-decoration-color",
        "text-decoration-style", "text-transform", "text-align", "text-indent",
        "vertical-align", "line-height", "letter-spacing", "word-spacing", "white-space",
        "direction",
        "padding", "padding-top", "padding-right", "padding-bottom", "padding-left",
        "margin", "margin-top", "margin-right", "margin-bottom", "margin-left",
        "border", "border-top", "border-right", "border-bottom", "border-left",
        "border-width", "border-style", "border-color", "border-radius",
        "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
        "border-top-style", "border-right-style", "border-bottom-style", "border-left-style",
        "border-top-color", "border-right-color", "border-bottom-color", "border-left-color",
        "border-collapse", "border-spacing",
        "width", "max-width", "min-width", "min-height",
        "display",
    ]

    static let allowedDisplay: Set<String> = [
        "block", "inline", "inline-block", "table", "inline-table", "table-row",
        "table-cell", "table-row-group", "list-item",
    ]

    private final class Box: NSObject {
        let value: Result?
        init(_ value: Result?) { self.value = value }
    }
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 64
        return cache
    }()

    /// `sanitize`, remembered per input: the compose and Settings previews
    /// rebuild on every render, and a stored signature does not change.
    static func cachedSanitize(_ html: String) -> Result? {
        let key = html as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let value = sanitize(html)
        cache.setObject(Box(value), forKey: key)
        return value
    }

    /// Rebuilt HTML, or nil when nothing could be read (too large, not
    /// parseable, or no text left).
    static func sanitize(_ html: String) -> Result? {
        guard html.utf16.count <= SignatureImport.maxInputLength,
              let ready = prepare(html), ready.depth <= maxDepth else { return nil }
        let wrapped = "<html><body>\(ready.html)</body></html>"
        guard let doc = try? XMLDocument(xmlString: wrapped, options: [.documentTidyHTML]),
              let root = doc.rootElement() else { return nil }
        let body = root.elements(forName: "body").first ?? root
        // The parser wraps lines; a space it leaves before a block's end
        // changes nothing on screen, so it goes too.
        let out = (body.children ?? []).map { write($0, depth: 0) }.joined()
            .replacingOccurrences(of: #"\s+(</(div|p|td|th|tr|li|table|tbody|thead|tfoot|ul|ol|center|h[1-6])>)"#,
                                  with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = out.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .decodingHTMLEntities()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty else { return nil }
        return Result(html: out)
    }

    /// Before the parser, in one linear pass (no backtracking regex, so a
    /// hostile signature cannot stall a refresh): comments, declarations
    /// (`<!DOCTYPE …>` with any internal subset, `<?…?>`) and the elements
    /// dropped with their content go; every tag DreaMail does not know
    /// loses its tags, content kept, so the HTML 4 parser never meets one
    /// it rejects (`<svg>`, `<o:p>`, `<wbr>`). An opener with no end (a
    /// comment, a tag, a dropped element) ends the input there. Also
    /// returns the deepest nesting of kept elements. Shared with
    /// `SignatureImport`.
    static func prepare(_ html: String) -> (html: String, depth: Int)? {
        var out = ""
        var depth = 0, deepest = 0
        var i = html.startIndex
        while let lt = html[i...].firstIndex(of: "<") {
            out += html[i..<lt]
            let rest = html[lt...]
            if rest.hasPrefix("<!--") {
                guard let end = rest.range(of: "-->") else { return (out, deepest) }
                i = end.upperBound
                continue
            }
            if rest.hasPrefix("<!") || rest.hasPrefix("<?") {
                guard let gt = rest.firstIndex(of: ">") else { return (out, deepest) }
                // An internal subset (`[ … ]`) may hold `>` of its own.
                if let open = rest[..<gt].firstIndex(of: "[") {
                    guard let close = rest[open...].range(of: "]"),
                          let end = rest[close.upperBound...].firstIndex(of: ">")
                    else { return (out, deepest) }
                    i = html.index(after: end)
                } else {
                    i = html.index(after: gt)
                }
                continue
            }
            let afterLT = html.index(after: lt)
            var nameStart = afterLT
            let closing = nameStart < html.endIndex && html[nameStart] == "/"
            if closing { nameStart = html.index(after: nameStart) }
            var nameEnd = nameStart
            while nameEnd < html.endIndex,
                  html[nameEnd].isLetter || html[nameEnd].isNumber
                    || ":_-".contains(html[nameEnd]) {
                nameEnd = html.index(after: nameEnd)
            }
            guard nameEnd > nameStart, html[nameStart].isLetter else {
                // A "<" that starts no tag is text.
                out += "&lt;"
                i = afterLT
                continue
            }
            guard let gt = html[nameEnd...].firstIndex(of: ">") else { return (out, deepest) }
            let name = html[nameStart..<nameEnd].lowercased()
            let tag = html[lt...gt]
            i = html.index(after: gt)
            if droppedWhole.contains(name) {
                guard !closing, !tag.hasSuffix("/>"),
                      !["link", "meta", "input", "base"].contains(name) else { continue }
                guard let end = html[i...].range(of: "</\(name)", options: .caseInsensitive),
                      let endGT = html[end.upperBound...].firstIndex(of: ">")
                else { return (out, deepest) }
                out += " "
                i = html.index(after: endGT)
                continue
            }
            guard allowedElements.contains(name) || name == "img" else { continue }
            out += tag
            if name == "img" || voidElements.contains(name) || tag.hasSuffix("/>") { continue }
            if closing {
                depth = max(0, depth - 1)
            } else {
                depth += 1
                deepest = max(deepest, depth)
            }
        }
        out += html[i...]
        return (out, deepest)
    }

    // MARK: - Writing

    private static func write(_ node: XMLNode, depth: Int) -> String {
        guard depth <= maxDepth else { return "" }
        switch node.kind {
        case .text:
            // HTML folds white space; the parser may wrap long lines.
            return escapeText(SignatureImport.stripInvisible(node.stringValue ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression))
        case .element:
            guard let element = node as? XMLElement else { return "" }
            let name = (element.name ?? "").lowercased()
            if name == "img" || droppedWhole.contains(name) { return "" }
            let inner = (element.children ?? []).map {
                write($0, depth: depth + 1)
            }.joined()
            guard allowedElements.contains(name) else { return inner }
            var attrs = attributes(of: element, name: name)
            if name == "a" {
                if let href = link(of: element) {
                    attrs.insert("href=\"\(escapeAttribute(href))\"", at: 0)
                } else {
                    // A link that cannot be kept stays as its text.
                    return inner
                }
            }
            let open = attrs.isEmpty ? "<\(name)>" : "<\(name) \(attrs.joined(separator: " "))>"
            return voidElements.contains(name) ? open : open + inner + "</\(name)>"
        default:
            return ""
        }
    }

    private static func attributes(of element: XMLElement, name: String) -> [String] {
        var out: [String] = []
        for attr in element.attributes ?? [] {
            let key = (attr.name ?? "").lowercased()
            let value = (attr.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowedAttributes.contains(key), !value.isEmpty else { continue }
            let kept: String?
            if key == "height", !heightElements.contains(name) { continue }
            switch key {
            case "style":
                let style = filterStyle(value)
                kept = style.isEmpty ? nil : style
            case "width", "height", "border", "cellpadding", "cellspacing", "colspan",
                 "rowspan", "size":
                kept = value.range(of: #"^[+]?[0-9]{1,4}(\.[0-9]+)?(px|%)?$"#,
                                   options: .regularExpression) != nil ? value : nil
            case "dir":
                kept = ["ltr", "rtl", "auto"].contains(value.lowercased()) ? value : nil
            case "align", "valign":
                kept = value.range(of: #"^[A-Za-z]{1,10}$"#, options: .regularExpression) != nil
                    ? value : nil
            default:
                kept = isSafeValue(value) ? value : nil
            }
            if let kept { out.append("\(key)=\"\(escapeAttribute(kept))\"") }
        }
        return out
    }

    /// The href of a link DreaMail keeps, or nil.
    private static func link(of element: XMLElement) -> String? {
        guard let raw = element.attribute(forName: "href")?.stringValue,
              let url = ComposeLinks.normalizeURL(raw) else { return nil }
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://")
                || lower.hasPrefix("mailto:") else { return nil }
        let label = (element.stringValue ?? "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if !label.isEmpty, SignatureImport.labelNamesOtherAddress(label, than: url) { return nil }
        return url
    }

    /// The declarations of a `style` attribute that are kept.
    static func filterStyle(_ style: String) -> String {
        style.split(separator: ";").compactMap { declaration -> String? in
            guard let colon = declaration.firstIndex(of: ":") else { return nil }
            let property = declaration[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = declaration[declaration.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowedProperties.contains(property), !value.isEmpty, isSafeValue(value)
            else { return nil }
            let lower = value.lowercased()
            if property == "display",
               !allowedDisplay.contains(lower.replacingOccurrences(of: "!important", with: "")
                .trimmingCharacters(in: .whitespaces)) { return nil }
            // Nothing may pull the signature over the text around it: no
            // negative value anywhere, no line height below one line.
            if lower.range(of: #"(^|[\s,(:])-\s*\.?[0-9]"#, options: .regularExpression) != nil {
                return nil
            }
            if property == "line-height", !isAtLeastOneLine(lower) { return nil }
            return "\(property):\(value)"
        }.joined(separator: ";")
    }

    /// A line height of at least one line: "normal", a number or em/rem of
    /// at least 1, a percentage of at least 100, or 10px/pt and more.
    static func isAtLeastOneLine(_ value: String) -> Bool {
        let v = value.replacingOccurrences(of: "!important", with: "")
            .trimmingCharacters(in: .whitespaces)
        if v == "normal" { return true }
        let units: [(String, Double)] = [("rem", 1), ("em", 1), ("%", 100), ("px", 10), ("pt", 10)]
        for (unit, minimum) in units where v.hasSuffix(unit) {
            return Double(v.dropLast(unit.count)).map { $0 >= minimum } ?? false
        }
        return Double(v).map { $0 >= 1 } ?? false
    }

    /// Plain words, numbers, lengths, `#` colours, quoted font names and
    /// colour functions; nothing that can load, run or escape.
    static func isSafeValue(_ value: String) -> Bool {
        let lower = value.lowercased()
        for bad in ["url", "expression", "javascript", "vbscript", "behavior", "binding",
                    "image", "attr", "var(", "calc", "\\", "@", "<", ">", "{", "}", "/*", "&"]
        where lower.contains(bad) { return false }
        let withoutColours = lower.replacingOccurrences(
            of: #"\b(rgb|rgba|hsl|hsla)\(\s*[0-9.,%\s/]*\)"#, with: "", options: .regularExpression)
        if withoutColours.contains("(") || withoutColours.contains(")") { return false }
        return withoutColours.range(of: #"^[a-z0-9#%.,\-_!'" ]*$"#,
                                    options: .regularExpression) != nil
    }

    private static func escapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ s: String) -> String {
        escapeText(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
