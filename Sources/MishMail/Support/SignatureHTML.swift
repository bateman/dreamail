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
/// client from what MishMail sends), event handlers, classes and ids, and
/// any style with `url(`, `expression`, `position`, escapes, or a negative
/// margin (which could pull it over the text around it). Text is escaped.
enum SignatureHTML {
    struct Result: Equatable {
        var html: String
        var droppedImages: Int
    }

    static let allowedElements: Set<String> = [
        "div", "span", "p", "br", "hr", "b", "strong", "i", "em", "u", "s", "strike",
        "font", "a", "small", "big", "sub", "sup", "center",
        "table", "thead", "tbody", "tfoot", "tr", "td", "th",
        "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6",
    ]

    /// Dropped with their content.
    static let droppedWhole: Set<String> = [
        "script", "style", "head", "title", "noscript", "template", "form", "textarea",
        "select", "button", "object", "embed", "iframe", "frame", "frameset", "svg",
        "math", "link", "meta", "input", "base", "audio", "video", "canvas", "applet",
    ]

    static let voidElements: Set<String> = ["br", "hr"]

    static let allowedAttributes: Set<String> = [
        "style", "dir", "align", "valign", "width", "height", "bgcolor", "color", "face",
        "size", "border", "cellpadding", "cellspacing", "colspan", "rowspan",
    ]

    static let allowedProperties: Set<String> = [
        "color", "background-color",
        "font", "font-family", "font-size", "font-weight", "font-style", "font-variant",
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
        "width", "max-width", "min-width", "height", "max-height", "min-height",
        "display",
    ]

    static let allowedDisplay: Set<String> = [
        "block", "inline", "inline-block", "table", "inline-table", "table-row",
        "table-cell", "table-row-group", "list-item",
    ]

    /// Rebuilt HTML, or nil when nothing could be read (too large, not
    /// parseable, or no text left).
    static func sanitize(_ html: String) -> Result? {
        guard html.utf16.count <= SignatureImport.maxInputLength else { return nil }
        let wrapped = "<html><body>\(prepared(html))</body></html>"
        guard let doc = try? XMLDocument(xmlString: wrapped, options: [.documentTidyHTML]),
              let root = doc.rootElement() else { return nil }
        let body = root.elements(forName: "body").first ?? root
        var images = 0
        let out = (body.children ?? []).map { write($0, images: &images) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = out.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .decodingHTMLEntities()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty else { return nil }
        return Result(html: out, droppedImages: images)
    }

    /// Before the parser: comments and the elements dropped with their
    /// content go, and every tag MishMail does not know loses its tags
    /// (content kept), so the HTML 4 parser never meets a tag it rejects
    /// (`<svg>`, `<o:p>`, `<wbr>`).
    private static func prepared(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "",
                                          options: .regularExpression)
        for tag in droppedWhole.subtracting(["link", "meta", "input", "base"]) {
            s = s.replacingOccurrences(
                of: "<\\(tag)\\b[^>]*>[\\s\\S]*?</\\(tag)\\s*>", with: " ",
                options: [.regularExpression, .caseInsensitive])
        }
        guard let re = try? NSRegularExpression(pattern: #"</?([A-Za-z][A-Za-z0-9:_-]*)\b[^>]*>"#)
        else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = m.range.location + m.range.length
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            if allowedElements.contains(name) || name == "img" {
                out += ns.substring(with: m.range)
            }
        }
        out += ns.substring(from: last)
        return out
    }

    // MARK: - Writing

    private static func write(_ node: XMLNode, images: inout Int) -> String {
        switch node.kind {
        case .text:
            // HTML folds white space; the parser may wrap long lines.
            return escapeText(SignatureImport.stripInvisible(node.stringValue ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression))
        case .element:
            guard let element = node as? XMLElement else { return "" }
            let name = (element.name ?? "").lowercased()
            if name == "img" {
                images += 1
                return ""
            }
            if droppedWhole.contains(name) { return "" }
            let inner = (element.children ?? []).map { write($0, images: &images) }.joined()
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
            switch key {
            case "style":
                let style = filterStyle(value)
                kept = style.isEmpty ? nil : style
            case "width", "height", "border", "cellpadding", "cellspacing", "colspan",
                 "rowspan", "size":
                kept = value.range(of: #"^[+-]?[0-9]{1,4}(\.[0-9]+)?(px|%)?$"#,
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

    /// The href of a link MishMail keeps, or nil.
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
            if property.hasPrefix("margin"), lower.contains("-") { return nil }
            return "\(property):\(value)"
        }.joined(separator: ";")
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
