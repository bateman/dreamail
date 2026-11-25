import Foundation

/// What a message looks like from the outside, OpenPGP-wise: found by
/// reading MIME types, parameters, file names and ASCII-armor header lines,
/// never by parsing OpenPGP packets. Nothing here says whether a signature
/// is good or a message decrypts: that is the engine's answer
/// (`OpenPGPEngine`), and only `PGPSecurityRules` turns it into what the
/// user sees.
enum PGPFinding: Sendable, Equatable {
    /// RFC 3156 §5 `multipart/signed; protocol="application/pgp-signature"`
    /// with a signed part and a signature part.
    case mimeSigned
    /// RFC 3156 §4 `multipart/encrypted; protocol="application/pgp-encrypted"`
    /// with the version part and the `application/octet-stream` payload.
    case mimeEncrypted
    /// A `multipart/signed` or `multipart/encrypted` that names the OpenPGP
    /// protocol but does not have the shape RFC 3156 requires, or whose
    /// structure is ambiguous (`RawMIMEPart.isAmbiguous`) or was cut short
    /// by a parser limit. Shown as nothing better than an unsigned,
    /// unencrypted message.
    case malformedMIME
    /// `-----BEGIN PGP MESSAGE-----` in a text part.
    case inlineEncrypted
    /// `-----BEGIN PGP SIGNED MESSAGE-----` (cleartext signature framework).
    case inlineSigned
    /// `-----BEGIN PGP PUBLIC KEY BLOCK-----` in a text part.
    case inlinePublicKey
    /// An attachment that carries OpenPGP data by type or extension
    /// (`application/pgp-keys`, `.asc`, `.sig`, `.gpg`, `.pgp`).
    case attachment(PGPAttachmentKind)
}

enum PGPAttachmentKind: String, Sendable, Equatable {
    case publicKey, signature, encrypted, armored
}

/// One finding and where it is: the child indexes from the root entity
/// (`[]` is the message itself), and for inline armor whether anything else
/// shares the part (text outside the block, or another block), so the block
/// covers only part of it.
struct PGPLocatedFinding: Sendable, Equatable {
    let finding: PGPFinding
    let path: [Int]
    let hasTextOutsideArmor: Bool

    init(_ finding: PGPFinding, path: [Int], hasTextOutsideArmor: Bool = false) {
        self.finding = finding
        self.path = path
        self.hasTextOutsideArmor = hasTextOutsideArmor
    }

    /// True when the OpenPGP structure is the whole message: at the root,
    /// and for inline armor alone in a `text/plain` root. A mailing-list
    /// footer wrapped around a signed message, text pasted before an armored
    /// block, or a second block makes this false, and nothing may then be
    /// shown as signed or encrypted as a whole.
    var coversWholeMessage: Bool {
        guard !hasTextOutsideArmor else { return false }
        switch finding {
        case .mimeSigned, .mimeEncrypted, .inlineEncrypted, .inlineSigned: return path.isEmpty
        case .inlinePublicKey, .attachment, .malformedMIME: return false
        }
    }
}

/// A source-neutral view of a MIME tree, so the same rules read Gmail's
/// `format=full` payload (to decide which messages are worth fetching raw)
/// and a raw message (to verify one).
struct MIMEOutline: Sendable, Equatable {
    /// Text is decoded only for `text/plain` leaves up to this size; armor in
    /// a larger part is not looked for.
    static let maxTextBytes = 8 * 1024 * 1024

    let contentType: MIMEContentType
    let filename: String?
    /// Decoded body of a `text/plain` leaf, when the source has it.
    let text: String?
    let children: [MIMEOutline]
    /// This entity, or one inside it, was cut short by a parser limit.
    let truncated: Bool
    /// See `RawMIMEPart.isAmbiguous`.
    let isAmbiguous: Bool

    init(contentType: MIMEContentType, filename: String? = nil, text: String? = nil,
         children: [MIMEOutline] = [], truncated: Bool = false, isAmbiguous: Bool = false) {
        self.contentType = contentType
        self.filename = filename
        self.text = text
        self.children = children
        self.truncated = truncated || children.contains(where: \.truncated)
        self.isAmbiguous = isAmbiguous
    }

    init(raw part: RawMIMEPart, in data: Data) {
        let wantsText = part.contentType.mimeType == "text/plain" && part.children.isEmpty
            && part.bodyRange.count <= Self.maxTextBytes
        self.init(contentType: part.contentType,
                  filename: part.filename,
                  text: wantsText ? String(decoding: RawMIME.decodedBody(part, in: data),
                                           as: UTF8.self) : nil,
                  children: part.children.map { MIMEOutline(raw: $0, in: data) },
                  truncated: part.truncated,
                  isAmbiguous: part.isAmbiguous)
    }

    /// From Gmail's `format=full` tree. `mimeType` there has no parameters,
    /// so they are read from the part's own `Content-Type` header.
    init(gmail part: GMessage.Part) {
        let typeHeaders = (part.headers ?? []).filter { $0.name.lowercased() == "content-type" }
        var contentType = MIMEContentType(headerValue: typeHeaders.first?.value)
        if typeHeaders.isEmpty, let mime = part.mimeType?.lowercased(), !mime.isEmpty {
            contentType = MIMEContentType(mimeType: mime, parameters: [:])
        }
        let children = part.parts ?? []
        var text: String?
        if contentType.mimeType == "text/plain", children.isEmpty, let encoded = part.body?.data,
           encoded.utf8.count <= Self.maxTextBytes * 4 / 3 + 4,
           let decoded = MessageParser.decodeBase64URLData(encoded) {
            text = String(decoding: decoded, as: UTF8.self)
        }
        self.init(contentType: contentType,
                  filename: (part.filename?.isEmpty == false) ? part.filename : nil,
                  text: text,
                  children: children.map { MIMEOutline(gmail: $0) },
                  isAmbiguous: typeHeaders.count > 1 || contentType.hasDuplicateParameters
                      || contentType.hasExtendedParameters)
    }
}

enum PGPStructure {
    static let signatureProtocol = "application/pgp-signature"
    static let encryptedProtocol = "application/pgp-encrypted"

    /// Every OpenPGP finding in the tree, depth first. With the switch off it
    /// returns nothing and reads nothing.
    static func findings(in root: MIMEOutline, enabled: Bool) -> [PGPLocatedFinding] {
        guard enabled else { return [] }
        var out: [PGPLocatedFinding] = []
        walk(root, path: [], into: &out)
        return out
    }

    private static func walk(_ node: MIMEOutline, path: [Int], into out: inout [PGPLocatedFinding]) {
        let type = node.contentType
        let trustworthy = !node.truncated && !node.isAmbiguous
        switch type.mimeType {
        case "multipart/signed" where protocolIs(type, signatureProtocol):
            let wellFormed = trustworthy && isMIMESigned(type: type, children: node.children.map(\.contentType))
            out.append(PGPLocatedFinding(wellFormed ? .mimeSigned : .malformedMIME, path: path))
            // The signed part is walked like any other: an inline block or an
            // attachment inside it is still reported.
            if wellFormed, let signed = node.children.first {
                walk(signed, path: path + [0], into: &out)
            }
            return
        case "multipart/encrypted" where protocolIs(type, encryptedProtocol):
            let wellFormed = trustworthy && isMIMEEncrypted(type: type, children: node.children.map(\.contentType))
            out.append(PGPLocatedFinding(wellFormed ? .mimeEncrypted : .malformedMIME, path: path))
            return
        default:
            break
        }

        if let kind = attachmentKind(node) {
            out.append(PGPLocatedFinding(.attachment(kind), path: path))
            return
        }
        if let text = node.text {
            for armor in PGPArmor.blocks(in: text) {
                let finding: PGPFinding
                switch armor.kind {
                case .message: finding = .inlineEncrypted
                case .signedMessage: finding = .inlineSigned
                case .publicKey: finding = .inlinePublicKey
                }
                out.append(PGPLocatedFinding(finding, path: path,
                                             hasTextOutsideArmor: armor.hasTextOutside))
            }
        }
        for (index, child) in node.children.enumerated() {
            walk(child, path: path + [index], into: &out)
        }
    }

    private static func protocolIs(_ type: MIMEContentType, _ expected: String) -> Bool {
        type.parameters["protocol"]?.trimmingCharacters(in: .whitespaces).lowercased() == expected
    }

    /// Exactly two parts, the second `application/pgp-signature`. Content
    /// types only: no body is read.
    static func isMIMESigned(type: MIMEContentType, children: [MIMEContentType]) -> Bool {
        type.mimeType == "multipart/signed" && protocolIs(type, signatureProtocol)
            && children.count == 2 && children[1].mimeType == signatureProtocol
    }

    /// Exactly two parts: `application/pgp-encrypted`, then
    /// `application/octet-stream`. Content types only.
    static func isMIMEEncrypted(type: MIMEContentType, children: [MIMEContentType]) -> Bool {
        type.mimeType == "multipart/encrypted" && protocolIs(type, encryptedProtocol)
            && children.count == 2 && children[0].mimeType == encryptedProtocol
            && children[1].mimeType == "application/octet-stream"
    }

    static func attachmentKind(_ node: MIMEOutline) -> PGPAttachmentKind? {
        guard node.children.isEmpty else { return nil }
        switch node.contentType.mimeType {
        case "application/pgp-keys": return .publicKey
        case signatureProtocol: return .signature
        case encryptedProtocol: return .encrypted
        default: break
        }
        guard let name = node.filename?.lowercased() else { return nil }
        if name.hasSuffix(".sig") { return .signature }
        if name.hasSuffix(".gpg") || name.hasSuffix(".pgp") { return .encrypted }
        if name.hasSuffix(".asc") { return .armored }
        return nil
    }
}

/// ASCII-armor header lines (RFC 9580 §6.2), found at the start of a line
/// and paired with their end line. Only the three kinds a received message
/// can usefully carry are recognised; a private-key block is never looked
/// for (the app does not take private keys out of message bodies).
/// Private to this file: callers go through `PGPStructure.findings`, which
/// is gated by the switch.
private enum PGPArmor {
    enum Kind: CaseIterable {
        case message, signedMessage, publicKey

        var begin: String {
            switch self {
            case .message: return "-----BEGIN PGP MESSAGE-----"
            case .signedMessage: return "-----BEGIN PGP SIGNED MESSAGE-----"
            case .publicKey: return "-----BEGIN PGP PUBLIC KEY BLOCK-----"
            }
        }

        /// A cleartext-signed message ends with its signature block.
        var end: String {
            switch self {
            case .message: return "-----END PGP MESSAGE-----"
            case .signedMessage: return "-----END PGP SIGNATURE-----"
            case .publicKey: return "-----END PGP PUBLIC KEY BLOCK-----"
            }
        }
    }

    struct Block {
        let kind: Kind
        let hasTextOutside: Bool
    }

    /// Complete blocks only: a begin line without its end line is not one.
    /// Lines are compared with trailing spaces, tabs and CR removed; a line
    /// with anything before the dashes (a `> ` quote) is not a header line,
    /// so quoted armor in a reply is not taken for the message's own.
    ///
    /// Linear: the end lines of each kind are collected first, and a cursor
    /// per kind only moves forward, so a body full of unterminated begin
    /// lines costs one pass, not one pass per begin line.
    static func blocks(in text: String) -> [Block] {
        // "\r\n" is one Character in Swift, so split on both forms.
        let lines = text.split(omittingEmptySubsequences: false,
                               whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.trimmingTrailing() }
        var ends: [Kind: [Int]] = [:]
        for (index, line) in lines.enumerated() {
            for kind in Kind.allCases where line == kind.end {
                ends[kind, default: []].append(index)
            }
        }
        var cursor: [Kind: Int] = [:]
        var found: [(kind: Kind, lines: ClosedRange<Int>)] = []
        var i = 0
        while i < lines.count {
            guard let kind = Kind.allCases.first(where: { lines[i] == $0.begin }) else {
                i += 1
                continue
            }
            let kindEnds = ends[kind] ?? []
            var c = cursor[kind] ?? 0
            while c < kindEnds.count && kindEnds[c] <= i { c += 1 }
            cursor[kind] = c
            guard c < kindEnds.count else {
                i += 1
                continue
            }
            found.append((kind, i...kindEnds[c]))
            i = kindEnds[c] + 1
        }
        var covered = [Bool](repeating: false, count: lines.count)
        for block in found { for line in block.lines { covered[line] = true } }
        let textOutside = lines.indices.contains { !covered[$0] && !lines[$0].isEmpty }
        let outside = textOutside || found.count > 1
        return found.map { Block(kind: $0.kind, hasTextOutside: outside) }
    }
}

private extension Substring {
    func trimmingTrailing() -> String {
        var s = self
        while let last = s.last, last == " " || last == "\t" || last == "\r" { s = s.dropLast() }
        return String(s)
    }
}
