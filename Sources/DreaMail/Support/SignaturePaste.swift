import Foundation

/// A signature pasted into Settings → Signatures with its look (HTML on the
/// pasteboard, as Gmail's settings page puts it there). Untrusted input: it
/// goes through the same path as a signature Gmail returns. The text comes
/// from `SignatureImport` (the compose editor's Markdown), the look from
/// `SignatureHTML.sanitize` (allow-list, 10,000 characters, depth limit,
/// images dropped). Pure; nothing from the pasteboard is kept otherwise.
enum SignaturePaste {
    struct Result: Equatable {
        /// The signature's text, as the editor shows and text/plain sends it.
        var body: String
        /// The rebuilt look; nil when the sanitiser refused it (too long,
        /// too deep, nothing left): the text is then pasted on its own.
        var html: String?
        var droppedImages: Int
        var droppedLinks: Int

        /// One line for the sheet, or nil when nothing needs saying.
        var note: String? {
            var parts: [String] = []
            if html == nil { parts.append("The formatting could not be kept; the text was pasted.") }
            if droppedImages > 0 {
                parts.append(droppedImages == 1 ? "1 image was left out." : "\(droppedImages) images were left out.")
            }
            if droppedLinks > 0 {
                parts.append(droppedLinks == 1 ? "1 link was kept as text." : "\(droppedLinks) links were kept as text.")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    /// A browser copy puts long computed styles on every element, so the
    /// raw pasteboard HTML may be far over Gmail's 10,000 characters. Up to
    /// this much is read, and first reduced (`reduce`); the usual limits then
    /// apply to what is left.
    static let maxRawLength = 300_000

    /// Longer attribute values (other than `style`, which a browser fills
    /// with computed declarations) or style declarations are dropped before
    /// any check looks at them (no signature value comes near).
    static let maxAttributeLength = 2_048
    static let maxDeclarationLength = 256

    /// The pasted signature, or nil when no text could be read from the
    /// HTML (over the limits, or empty): the editor then pastes plain text.
    /// Linear before the 10,000-character limit: nothing super-linear sees
    /// the unreduced input. Slow enough for a big paste to run off the main
    /// thread.
    static func read(html raw: String) -> Result? {
        guard let html = reduce(raw) else { return nil }
        let text = SignatureImport.markdown(fromGmailHTML: html)
        guard !text.tooLarge, !text.body.isEmpty else { return nil }
        return Result(body: text.body, html: SignatureHTML.sanitize(html)?.html,
                      droppedImages: text.droppedImages, droppedLinks: text.droppedLinks)
    }

    /// What the sanitiser would drop anyway goes, in linear passes:
    /// comments (the StartFragment markers too), declarations, dropped and
    /// unknown elements (`SignatureHTML.prepare`), then every attribute not
    /// on the allow-list and every style declaration not on it. Nil over
    /// `maxRawLength`.
    static func reduce(_ html: String) -> String? {
        guard html.utf16.count <= maxRawLength else { return nil }
        let prepared = SignatureHTML.prepare(html).html
        var out = ""
        out.reserveCapacity(min(prepared.utf8.count, SignatureImport.maxInputLength * 2))
        var i = prepared.startIndex
        while let lt = prepared[i...].firstIndex(of: "<") {
            out += prepared[i..<lt]
            // `prepare` leaves only whole tags ("<" in text is escaped).
            guard let gt = prepared[lt...].firstIndex(of: ">") else {
                i = prepared.endIndex
                break
            }
            out += reducedTag(prepared[prepared.index(after: lt)..<gt])
            i = prepared.index(after: gt)
        }
        out += prepared[i...]
        return out
    }

    /// One tag (between "<" and ">") with only the attributes kept.
    private static func reducedTag(_ tag: Substring) -> String {
        var j = tag.startIndex
        var closing = false
        if j < tag.endIndex, tag[j] == "/" { closing = true; j = tag.index(after: j) }
        let nameStart = j
        while j < tag.endIndex, !tag[j].isWhitespace, tag[j] != "/" { j = tag.index(after: j) }
        let name = tag[nameStart..<j].lowercased()
        if closing { return "</\(name)>" }
        var attrs: [String] = []
        while j < tag.endIndex {
            while j < tag.endIndex, tag[j].isWhitespace || tag[j] == "/" { j = tag.index(after: j) }
            let keyStart = j
            while j < tag.endIndex, !tag[j].isWhitespace, tag[j] != "=", tag[j] != "/" {
                j = tag.index(after: j)
            }
            let key = tag[keyStart..<j].lowercased()
            while j < tag.endIndex, tag[j].isWhitespace { j = tag.index(after: j) }
            var value: Substring?
            if j < tag.endIndex, tag[j] == "=" {
                j = tag.index(after: j)
                while j < tag.endIndex, tag[j].isWhitespace { j = tag.index(after: j) }
                if j < tag.endIndex, tag[j] == "\"" || tag[j] == "'" {
                    let quote = tag[j]
                    let start = tag.index(after: j)
                    let end = tag[start...].firstIndex(of: quote) ?? tag.endIndex
                    value = tag[start..<end]
                    j = end < tag.endIndex ? tag.index(after: end) : end
                } else {
                    let start = j
                    while j < tag.endIndex, !tag[j].isWhitespace { j = tag.index(after: j) }
                    value = tag[start..<j]
                }
            }
            guard !key.isEmpty, let value,
                  key == "style" || value.utf16.count <= maxAttributeLength,
                  key == "href" || SignatureHTML.allowedAttributes.contains(key) else { continue }
            var kept = String(value)
            if key == "style" {
                // Entities first (linear): Chrome writes `&quot;Google
                // Sans&quot;`, whose `;` would otherwise split a declaration.
                kept = String(value).decodingHTMLEntities().split(separator: ";")
                    .filter { $0.utf16.count <= maxDeclarationLength }
                    .filter { declaration in
                        guard let colon = declaration.firstIndex(of: ":") else { return false }
                        let property = declaration[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                        return SignatureHTML.allowedProperties.contains(property)
                    }
                    .joined(separator: ";")
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                guard !kept.isEmpty else { continue }
            }
            attrs.append("\(key)=\"\(kept.replacingOccurrences(of: "\"", with: "&quot;"))\"")
        }
        return attrs.isEmpty ? "<\(name)>" : "<\(name) \(attrs.joined(separator: " "))>"
    }

    /// Said when the pasteboard had HTML that gave no text at all.
    static let unreadableNote = "The formatting could not be kept; the text was pasted."
}
