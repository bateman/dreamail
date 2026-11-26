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

    /// The pasted signature, or nil when no text could be read from the
    /// HTML (over the limit, or empty): the editor then pastes plain text.
    static func read(html: String) -> Result? {
        let text = SignatureImport.markdown(fromGmailHTML: html)
        guard !text.tooLarge, !text.body.isEmpty else { return nil }
        return Result(body: text.body, html: SignatureHTML.sanitize(html)?.html,
                      droppedImages: text.droppedImages, droppedLinks: text.droppedLinks)
    }

    /// Said when the pasteboard had HTML that gave no text at all.
    static let unreadableNote = "The formatting could not be kept; the text was pasted."
}
