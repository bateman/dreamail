import Foundation

/// "Import from Gmail": turns the HTML signature Gmail keeps for a send-as
/// address (`users.settings.sendAs.signature`) into the compose editor's
/// Markdown, which is how every DreaMail signature is stored.
///
/// Only what the editor can express survives: text, line breaks, bold,
/// italic, lists, and links whose scheme `ComposeLinks.normalizeURL`
/// accepts (http, https, mailto). Every tag is dropped, with the content of
/// scripts, styles, forms and form controls, and every attribute with it
/// (so no event handler or style). Images are dropped and counted: the
/// compose editor has no images, so composed mail never carries remote ones.
/// The result is then sent through the same Markdown renderer, which escapes
/// all text, as anything typed in compose.
enum SignatureImport {
    struct Result: Equatable {
        var body: String
        var droppedImages: Int
        /// Links kept as text only: a scheme other than http, https or
        /// mailto, or a label that names another address than the link.
        var droppedLinks = 0
        /// Over `maxInputLength`: nothing was read.
        var tooLarge = false
    }

    /// Gmail caps a signature at 10,000 characters; markup on top of that
    /// stays well under this. Larger input is refused before any pass.
    static let maxInputLength = 50_000

    static func markdown(fromGmailHTML html: String) -> Result {
        guard html.utf16.count <= maxInputLength else {
            return Result(body: "", droppedImages: 0, tooLarge: true)
        }
        var s = html.replacingOccurrences(of: "\r\n", with: "\n")
        // Gmail stores line breaks as tags; source newlines are layout.
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "",
                                   options: .regularExpression)
        // Elements dropped whole, content included.
        for tag in ["script", "style", "head", "title", "noscript", "template", "form",
                    "textarea", "select", "button", "object", "iframe", "svg", "math"] {
            s = s.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)\\s*>", with: " ",
                options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: #"<(link|meta|input)\b[^>]*>"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        let images = count(#"<img\b"#, in: s)
        s = s.replacingOccurrences(of: #"<img\b[^>]*>"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        let links = replaceLinks(s)
        s = links.text
        s = wrap(s, tags: "b|strong", marker: "**")
        s = wrap(s, tags: "i|em", marker: "*")
        s = replaceLists(s)
        // Block ends and breaks become newlines.
        s = s.replacingOccurrences(of: #"<br\b[^>]*>"#, with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        // Block boundaries: a run of them (</div><div>, </tr><tr>) is one
        // line break; an empty block holding a <br> is still a blank line.
        s = s.replacingOccurrences(of: #"</?(div|p|tr|table|h[1-6]|blockquote|center)\b[^>]*>"#,
                                   with: "\u{1E}", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "\u{1E}[ \t]*(?:\u{1E}[ \t]*)*", with: "\n",
                                   options: .regularExpression)
        // Table cells side by side: keep them apart.
        s = s.replacingOccurrences(of: #"</t[dh]\s*>"#, with: " ",
                                   options: [.regularExpression, .caseInsensitive])
        // Everything else that looks like a tag goes, attributes and all.
        s = s.replacingOccurrences(of: #"</?[A-Za-z][^>]*>"#, with: "",
                                   options: .regularExpression)
        s = stripInvisible(s.decodingHTMLEntities()
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\t", with: " "))
        let lines = s.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        var out: [String] = []
        for line in lines {
            if line.isEmpty, out.last?.isEmpty ?? true { continue }
            out.append(line)
        }
        return Result(body: ComposeSignature.normalizedBody(out.joined(separator: "\n")),
                      droppedImages: images, droppedLinks: links.dropped)
    }

    /// Bidi overrides and isolates (which can make text read other than it
    /// is), zero-width characters and C0 controls other than the newline.
    static func stripInvisible(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x0A: return true
            case 0x00...0x1F, 0x7F: return false
            case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: return false
            default: return true
            }
        }))
    }

    // MARK: - Pieces

    private static func count(_ pattern: String, in s: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return 0
        }
        return re.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    /// `<a href="…">text</a>` → `[text](url)` for an accepted URL, else the
    /// text alone. A link with no text (it held an image) is dropped. A
    /// label that is itself an address other than the link's becomes
    /// "label (url)" in plain text, so the mismatch shows. Text and URL
    /// have `&` re-escaped: the final pass decodes entities once.
    private static func replaceLinks(_ s: String) -> (text: String, dropped: Int) {
        let pattern = #"<a\b([^>]*)>([\s\S]*?)</a\s*>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return (s, 0)
        }
        let ns = s as NSString
        var out = ""
        var last = 0
        var dropped = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = m.range.location + m.range.length
            let attrs = ns.substring(with: m.range(at: 1))
            let text = plainText(ns.substring(with: m.range(at: 2)))
            guard !text.isEmpty else { continue }
            let rawHref = Self.href(in: attrs)
            guard let hrefValue = rawHref, let url = ComposeLinks.normalizeURL(hrefValue),
                  url.lowercased().hasPrefix("http") || url.lowercased().hasPrefix("mailto:")
            else {
                if rawHref != nil { dropped += 1 }
                out += reescaped(text)
                continue
            }
            if labelNamesOtherAddress(text, than: url) {
                dropped += 1
                out += reescaped("\(text) (\(url))")
                continue
            }
            out += "[\(reescaped(escapeLinkText(text)))](\(reescaped(escapeLinkURL(url))))"
        }
        out += ns.substring(from: last)
        return (out, dropped)
    }

    private static func reescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
    }

    /// True when the label reads as a URL or an address whose host differs
    /// from the link's.
    static func labelNamesOtherAddress(_ label: String, than url: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(" "), trimmed.contains("."),
              let labelURL = ComposeLinks.normalizeURL(trimmed) else { return false }
        return host(of: labelURL) != host(of: url)
    }

    private static func host(of url: String) -> String {
        let lower = url.lowercased()
        if lower.hasPrefix("mailto:") {
            return String(lower.dropFirst("mailto:".count).split(separator: "?").first ?? "")
        }
        var host = URL(string: lower)?.host ?? lower
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private static func href(in attributes: String) -> String? {
        let pattern = #"\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: attributes,
                                    range: NSRange(attributes.startIndex..., in: attributes))
        else { return nil }
        for i in 1...3 {
            if let r = Range(m.range(at: i), in: attributes) {
                return String(attributes[r]).decodingHTMLEntities()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// The visible text of an inline fragment, on one line.
    private static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
            .decodingHTMLEntities()
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func escapeLinkText(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }

    private static func escapeLinkURL(_ url: String) -> String {
        url.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    /// `<b> text </b>` → ` **text** `: markers hug the text, as Markdown
    /// needs, and a run with no text loses its tags only.
    private static func wrap(_ s: String, tags: String, marker: String) -> String {
        let pattern = "<(\(tags))\\b[^>]*>([\\s\\S]*?)</\\1\\s*>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return s
        }
        var current = s
        // Nested runs (<b><b>x</b></b>) resolve from the inside out.
        for _ in 0..<4 {
            let ns = current as NSString
            let matches = re.matches(in: current, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { break }
            var out = ""
            var last = 0
            for m in matches {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                last = m.range.location + m.range.length
                let inner = ns.substring(with: m.range(at: 2))
                let visible = plainText(inner)
                guard !visible.isEmpty,
                      inner.range(of: "<(br|div|p)\\b", options: [.regularExpression, .caseInsensitive]) == nil
                else {
                    out += inner
                    continue
                }
                let lead = inner.prefix(while: { $0.isWhitespace })
                let trail = String(inner.reversed().prefix(while: { $0.isWhitespace }))
                let core = inner.trimmingCharacters(in: .whitespaces)
                out += "\(lead)\(marker)\(core)\(marker)\(trail)"
            }
            out += ns.substring(from: last)
            current = out
        }
        return current
    }

    /// `<ul>/<ol>` items → `- item` / `1. item` lines.
    private static func replaceLists(_ s: String) -> String {
        var current = s
        let ordered = #"<ol\b[^>]*>([\s\S]*?)</ol\s*>"#
        if let re = try? NSRegularExpression(pattern: ordered, options: .caseInsensitive) {
            let ns = current as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: current, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                last = m.range.location + m.range.length
                let items = listItems(ns.substring(with: m.range(at: 1)))
                out += "\n" + items.enumerated().map { "\($0.offset + 1). \($0.element)" }
                    .joined(separator: "\n") + "\n"
            }
            out += ns.substring(from: last)
            current = out
        }
        current = current.replacingOccurrences(of: #"<li\b[^>]*>"#, with: "\n- ",
                                               options: [.regularExpression, .caseInsensitive])
        current = current.replacingOccurrences(of: #"</li\s*>"#, with: "",
                                               options: [.regularExpression, .caseInsensitive])
        current = current.replacingOccurrences(of: #"<ul\b[^>]*>"#, with: "",
                                               options: [.regularExpression, .caseInsensitive])
        current = current.replacingOccurrences(of: #"</ul\s*>"#, with: "\n",
                                               options: [.regularExpression, .caseInsensitive])
        return current
    }

    private static func listItems(_ html: String) -> [String] {
        html.components(separatedBy: "<li").dropFirst().compactMap { chunk in
            guard let close = chunk.firstIndex(of: ">") else { return nil }
            let body = chunk[chunk.index(after: close)...]
                .replacingOccurrences(of: #"</li\s*>"#, with: "",
                                      options: [.regularExpression, .caseInsensitive])
            let text = body.replacingOccurrences(of: #"<(?!/?a\b)[^>]*>"#, with: " ",
                                                 options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
    }
}
