import Foundation

/// A structure-only reader of a raw RFC 5322 / MIME message (Gmail's
/// `format=raw`) that keeps every part's exact byte range in the source.
///
/// It exists for one reason: an OpenPGP/MIME signature (RFC 3156 §5) covers
/// the exact bytes of the first body part of a `multipart/signed`, headers
/// included, and those bytes are not recoverable from Gmail's `format=full`
/// tree, which hands back decoded bodies. It splits multipart bodies by
/// boundary (RFC 2046 §5.1.1), unfolds headers and reads `Content-Type`
/// parameters; it does not decode charsets, RFC 2047 words or RFC 2231
/// continuations, and it knows nothing about OpenPGP packets.
///
/// Cost: one linear scan of the bytes per nesting level, and nesting is
/// bounded (`maxDepth`), as is the total number of parts (`maxParts`). A
/// multipart whose children were not all read because a limit was hit is
/// marked `truncated`; nothing may be trusted about its structure.
struct RawMIMEPart: Sendable, Equatable {
    /// Header name (lowercased) and unfolded value, in source order.
    struct Header: Sendable, Equatable {
        let name: String
        let value: String
    }

    /// Bytes of the whole entity: headers, separator line and body. For a
    /// body part this starts right after the delimiter line and ends before
    /// the line break that precedes the next delimiter (RFC 2046: that line
    /// break belongs to the delimiter, not to the part).
    let range: Range<Int>
    /// Bytes of the body alone (after the blank line).
    let bodyRange: Range<Int>
    let headers: [Header]
    let contentType: MIMEContentType
    /// Body parts of a multipart entity, empty otherwise.
    let children: [RawMIMEPart]
    /// A multipart whose body parts were not all read (depth or part limit).
    let truncated: Bool

    /// The structure can be read in more than one way: `Content-Type`
    /// appears more than once, a parameter is repeated, or a parameter uses
    /// RFC 2231 syntax (`boundary*=`), which this reader does not decode but
    /// another one might. An OpenPGP entity with any of these is malformed.
    var isAmbiguous: Bool {
        headers.filter { $0.name == "content-type" }.count > 1
            || contentType.hasDuplicateParameters || contentType.hasExtendedParameters
    }

    func header(_ name: String) -> String? {
        let key = name.lowercased()
        return headers.first { $0.name == key }?.value
    }

    var transferEncoding: String {
        (header("content-transfer-encoding") ?? "7bit")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The file name from `Content-Disposition` or, failing that, the
    /// `name` parameter of `Content-Type`.
    var filename: String? {
        if let disposition = header("content-disposition"),
           let name = MIMEContentType.parameters(of: disposition)["filename"], !name.isEmpty {
            return name
        }
        if let name = contentType.parameters["name"], !name.isEmpty { return name }
        return nil
    }
}

/// `type/subtype` (lowercased) and its parameters (names lowercased, values
/// unquoted, case preserved).
struct MIMEContentType: Sendable, Equatable {
    let mimeType: String
    let parameters: [String: String]
    /// A parameter name appeared more than once (the first value is kept).
    let hasDuplicateParameters: Bool
    /// A parameter name ends in `*` or `*<n>` (RFC 2231), e.g. `boundary*0=`.
    let hasExtendedParameters: Bool

    static let defaultText = MIMEContentType(mimeType: "text/plain", parameters: [:])

    var isMultipart: Bool { mimeType.hasPrefix("multipart/") }

    init(mimeType: String, parameters: [String: String],
         hasDuplicateParameters: Bool = false, hasExtendedParameters: Bool = false) {
        self.mimeType = mimeType
        self.parameters = parameters
        self.hasDuplicateParameters = hasDuplicateParameters
        self.hasExtendedParameters = hasExtendedParameters
    }

    /// Parses a `Content-Type` value. A value without a well-formed
    /// `type/subtype` is `text/plain` (RFC 2045 §5.2).
    init(headerValue: String?) {
        guard let headerValue else { self = .defaultText; return }
        let fields = Self.splitFields(headerValue)
        let type = (fields.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let pieces = type.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty,
              !type.contains(where: { $0 == " " || $0 == "\"" }) else {
            self = .defaultText
            return
        }
        let parsed = Self.parsedParameters(fields.dropFirst())
        self.init(mimeType: type, parameters: parsed.values,
                  hasDuplicateParameters: parsed.duplicates,
                  hasExtendedParameters: parsed.values.keys.contains { $0.contains("*") })
    }

    /// The `key=value` parameters after the first `;` of a header value.
    static func parameters(of headerValue: String) -> [String: String] {
        parsedParameters(splitFields(headerValue).dropFirst()).values
    }

    private static func parsedParameters(_ fields: ArraySlice<String>)
        -> (values: [String: String], duplicates: Bool) {
        var out: [String: String] = [:]
        var duplicates = false
        for field in fields {
            guard let eq = field.firstIndex(of: "=") else { continue }
            let key = field[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = field[field.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") {
                value = unquote(value)
            }
            // First occurrence wins, and the repetition is recorded: a later
            // duplicate must not be able to replace the boundary silently.
            guard !key.isEmpty else { continue }
            if out[key] == nil { out[key] = value } else { duplicates = true }
        }
        return (out, duplicates)
    }

    /// Splits on `;` outside quoted strings.
    private static func splitFields(_ value: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in value {
            if escaped { current.append(ch); escaped = false; continue }
            if inQuotes && ch == "\\" { current.append(ch); escaped = true; continue }
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields
    }

    private static func unquote(_ value: String) -> String {
        var out = ""
        var escaped = false
        for ch in value.dropFirst() {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { break }
            out.append(ch)
        }
        return out
    }
}

enum RawMIME {
    static let maxDepth = 16
    static let maxParts = 512

    /// Parses a whole message.
    static func parse(_ data: Data) -> RawMIMEPart {
        let bytes = [UInt8](data)
        var budget = maxParts
        return parseEntity(bytes, 0..<bytes.count, depth: 0, budget: &budget)
    }

    /// The bytes of `range` in `data`, unchanged.
    static func bytes(_ data: Data, _ range: Range<Int>) -> Data {
        data.subdata(in: (data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound))
    }

    /// RFC 3156 §5 canonical form: every line break is CRLF. A bare LF
    /// (a message stored or relayed with Unix line endings) becomes CRLF; an
    /// existing CRLF is kept; a bare CR is left alone (it is not a line
    /// break in RFC 5322 and an engine must see it as sent). Nothing else
    /// changes: no trailing-whitespace stripping, no charset conversion.
    static func canonicalCRLF(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + bytes.count / 32)
        var runStart = 0
        for i in bytes.indices where bytes[i] == 0x0A && (i == 0 || bytes[i - 1] != 0x0D) {
            out.append(contentsOf: bytes[runStart..<i])
            out.append(0x0D)
            runStart = i
        }
        out.append(contentsOf: bytes[runStart...])
        return Data(out)
    }

    /// The body of `part` with its Content-Transfer-Encoding undone (base64,
    /// quoted-printable; anything else unchanged). Charset is not touched.
    static func decodedBody(_ part: RawMIMEPart, in data: Data) -> Data {
        let body = bytes(data, part.bodyRange)
        switch part.transferEncoding {
        case "base64":
            return Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return decodeQuotedPrintable(body)
        default:
            return body
        }
    }

    // MARK: - Entities

    private static func parseEntity(_ b: [UInt8], _ range: Range<Int>, depth: Int,
                                    budget: inout Int) -> RawMIMEPart {
        budget -= 1
        let (headerLines, bodyStart) = headerBlock(b, range)
        let headers = unfold(headerLines, b)
        let contentType = MIMEContentType(
            headerValue: headers.first { $0.name == "content-type" }?.value)
        let bodyRange = bodyStart..<range.upperBound

        var children: [RawMIMEPart] = []
        var truncated = false
        if contentType.isMultipart,
           let boundary = contentType.parameters["boundary"], isUsableBoundary(boundary) {
            if depth < maxDepth, budget > 0 {
                for childRange in bodyPartRanges(b, bodyRange, boundary: Array(boundary.utf8)) {
                    guard budget > 0 else { truncated = true; break }
                    children.append(parseEntity(b, childRange, depth: depth + 1, budget: &budget))
                }
            } else {
                truncated = true
            }
        }
        return RawMIMEPart(range: range, bodyRange: bodyRange, headers: headers,
                           contentType: contentType, children: children, truncated: truncated)
    }

    /// RFC 2046: 1–70 characters. Anything else is not split.
    private static func isUsableBoundary(_ boundary: String) -> Bool {
        !boundary.isEmpty && boundary.utf8.count <= 70 && !boundary.contains(where: \.isNewline)
    }

    /// Lines of the header block (each without its line break) and where the
    /// body starts. The header block ends at the first empty line; with no
    /// empty line the whole entity is headers and the body is empty. A part
    /// that starts with an empty line has no headers.
    private static func headerBlock(_ b: [UInt8], _ range: Range<Int>) -> ([Range<Int>], Int) {
        var lines: [Range<Int>] = []
        var i = range.lowerBound
        while i < range.upperBound {
            let (content, next) = line(b, from: i, end: range.upperBound)
            if content.isEmpty { return (lines, next) }
            lines.append(content)
            i = next
        }
        return (lines, range.upperBound)
    }

    /// The line starting at `start`: its content (without CR LF / LF) and the
    /// index after its line break.
    private static func line(_ b: [UInt8], from start: Int, end: Int) -> (Range<Int>, Int) {
        var j = start
        while j < end && b[j] != 0x0A { j += 1 }
        let next = j < end ? j + 1 : end
        var contentEnd = j
        if contentEnd > start && b[contentEnd - 1] == 0x0D && j < end { contentEnd -= 1 }
        return (start..<contentEnd, next)
    }

    private static func unfold(_ lines: [Range<Int>], _ b: [UInt8]) -> [RawMIMEPart.Header] {
        var out: [(String, String)] = []
        for line in lines {
            let text = String(decoding: b[line], as: UTF8.self)
            if let first = text.first, first == " " || first == "\t", !out.isEmpty {
                out[out.count - 1].1 += text
            } else if let colon = text.firstIndex(of: ":") {
                let name = text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = text[text.index(after: colon)...]
                out.append((name, String(value)))
            }
            // A line that is neither a field nor a continuation is dropped.
        }
        return out.map { RawMIMEPart.Header(name: $0.0,
                                            value: $0.1.trimmingCharacters(in: .whitespaces)) }
    }

    /// Byte ranges of the body parts of a multipart body.
    ///
    /// A delimiter line is `--boundary`, optionally followed by `--` (the
    /// close delimiter), then only spaces or tabs (RFC 2046 transport
    /// padding), at the start of a line. The line break before a delimiter
    /// belongs to the delimiter, so a part ends before it; a part starts after
    /// the delimiter line's own line break. Preamble and epilogue are not
    /// parts. Parts after an unterminated last delimiter run to the end.
    private static func bodyPartRanges(_ b: [UInt8], _ body: Range<Int>,
                                       boundary: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var partStart: Int?
        var i = body.lowerBound
        while i < body.upperBound {
            let lineStart = i
            let (content, next) = line(b, from: i, end: body.upperBound)
            if let close = delimiterKind(b, content, boundary) {
                if let start = partStart {
                    ranges.append(start..<max(start, lineBreakStart(b, before: lineStart,
                                                                     floor: start)))
                }
                if close { return ranges }
                partStart = next
            }
            i = next
        }
        if let start = partStart { ranges.append(start..<body.upperBound) }
        return ranges
    }

    /// nil when the line is not a delimiter; true for the close delimiter.
    private static func delimiterKind(_ b: [UInt8], _ line: Range<Int>,
                                      _ boundary: [UInt8]) -> Bool? {
        let dash = UInt8(ascii: "-")
        let prefixLength = 2 + boundary.count
        guard line.count >= prefixLength, b[line.lowerBound] == dash,
              b[line.lowerBound + 1] == dash,
              b[(line.lowerBound + 2)..<(line.lowerBound + prefixLength)].elementsEqual(boundary)
        else { return nil }
        var j = line.lowerBound + prefixLength
        var close = false
        if j + 2 <= line.upperBound, b[j] == dash, b[j + 1] == dash {
            close = true
            j += 2
        }
        while j < line.upperBound {
            guard b[j] == 0x20 || b[j] == 0x09 else { return nil }
            j += 1
        }
        return close
    }

    /// Index of the CRLF or LF that ends the line before `lineStart`, so the
    /// part excludes it. Never earlier than `floor` (an empty part).
    private static func lineBreakStart(_ b: [UInt8], before lineStart: Int, floor: Int) -> Int {
        var end = lineStart
        if end > floor && b[end - 1] == 0x0A {
            end -= 1
            if end > floor && b[end - 1] == 0x0D { end -= 1 }
        }
        return end
    }

    // MARK: - Quoted-printable (RFC 2045 §6.7)

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        let b = [UInt8](data)
        var out = Data()
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            let byte = b[i]
            guard byte == UInt8(ascii: "=") else {
                out.append(byte)
                i += 1
                continue
            }
            // Soft line break: "=" then optional whitespace then CRLF or LF.
            var j = i + 1
            while j < b.count && (b[j] == 0x20 || b[j] == 0x09) { j += 1 }
            if j < b.count && b[j] == 0x0D && j + 1 < b.count && b[j + 1] == 0x0A {
                i = j + 2
                continue
            }
            if j < b.count && b[j] == 0x0A {
                i = j + 1
                continue
            }
            if j == b.count {
                i = j
                continue
            }
            if i + 2 < b.count, let hi = hexValue(b[i + 1]), let lo = hexValue(b[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                // Not a valid escape: keep it literally (RFC 2045 §6.7 note 1).
                out.append(byte)
                i += 1
            }
        }
        return out
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
}
