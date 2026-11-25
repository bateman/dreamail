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
    /// protocol but does not have the shape RFC 3156 requires. Shown as
    /// nothing better than an unsigned, unencrypted message.
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
/// (`[]` is the message itself), and for inline armor whether text outside
/// the armored block shares the part (so the block covers only part of it).
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
    /// and for inline armor with nothing around it. A mailing-list footer
    /// wrapped around a signed message, or text pasted before an armored
    /// block, makes this false, and nothing may then be shown as signed or
    /// encrypted as a whole.
    var coversWholeMessage: Bool {
        guard !hasTextOutsideArmor else { return false }
        switch finding {
        case .mimeSigned, .mimeEncrypted: return path.isEmpty
        case .inlineEncrypted, .inlineSigned:
            // A single text part at the root, or the only text part of a
            // root multipart/alternative is not enough: the HTML sibling is
            // not covered. Only a text/plain root qualifies.
            return path.isEmpty
        case .inlinePublicKey, .attachment, .malformedMIME: return false
        }
    }
}

/// A source-neutral view of a MIME tree, so the same rules read Gmail's
/// `format=full` payload (to decide which messages are worth fetching raw)
/// and a raw message (to verify one).
struct MIMEOutline: Sendable, Equatable {
    let contentType: MIMEContentType
    let filename: String?
    /// Decoded body of a `text/*` leaf, when the source has it.
    let text: String?
    let children: [MIMEOutline]

    init(contentType: MIMEContentType, filename: String? = nil, text: String? = nil,
         children: [MIMEOutline] = []) {
        self.contentType = contentType
        self.filename = filename
        self.text = text
        self.children = children
    }

    init(raw part: RawMIMEPart, in data: Data) {
        let isText = part.contentType.mimeType.hasPrefix("text/") && part.children.isEmpty
        self.init(contentType: part.contentType,
                  filename: part.filename,
                  text: isText ? String(decoding: RawMIME.decodedBody(part, in: data),
                                        as: UTF8.self) : nil,
                  children: part.children.map { MIMEOutline(raw: $0, in: data) })
    }

    /// From Gmail's `format=full` tree. `mimeType` there has no parameters,
    /// so they are read from the part's own `Content-Type` header.
    init(gmail part: GMessage.Part) {
        let header = part.headers?.first { $0.name.lowercased() == "content-type" }?.value
        var contentType = MIMEContentType(headerValue: header)
        if header == nil, let mime = part.mimeType?.lowercased(), !mime.isEmpty {
            contentType = MIMEContentType(mimeType: mime, parameters: [:])
        }
        let isText = contentType.mimeType.hasPrefix("text/") && (part.parts ?? []).isEmpty
        let text = isText ? part.body?.data.flatMap { MessageParser.decodeBase64URLData($0) }
            .map { String(decoding: $0, as: UTF8.self) } : nil
        self.init(contentType: contentType,
                  filename: (part.filename?.isEmpty == false) ? part.filename : nil,
                  text: text,
                  children: (part.parts ?? []).map { MIMEOutline(gmail: $0) })
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
        switch type.mimeType {
        case "multipart/signed" where protocolIs(type, signatureProtocol):
            out.append(PGPLocatedFinding(isMIMESigned(node) ? .mimeSigned : .malformedMIME,
                                         path: path))
            // The signed part is walked like any other: an inline block or an
            // attachment inside it is still reported.
            if let signed = node.children.first {
                walk(signed, path: path + [0], into: &out)
            }
            return
        case "multipart/encrypted" where protocolIs(type, encryptedProtocol):
            out.append(PGPLocatedFinding(isMIMEEncrypted(node) ? .mimeEncrypted : .malformedMIME,
                                         path: path))
            return
        default:
            break
        }

        if let kind = attachmentKind(node) {
            out.append(PGPLocatedFinding(.attachment(kind), path: path))
            return
        }
        if type.mimeType == "text/plain", let text = node.text {
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

    /// Exactly two parts, the second `application/pgp-signature`.
    static func isMIMESigned(_ node: MIMEOutline) -> Bool {
        node.children.count == 2
            && node.children[1].contentType.mimeType == signatureProtocol
    }

    /// Exactly two parts: `application/pgp-encrypted`, then
    /// `application/octet-stream`.
    static func isMIMEEncrypted(_ node: MIMEOutline) -> Bool {
        node.children.count == 2
            && node.children[0].contentType.mimeType == encryptedProtocol
            && node.children[1].contentType.mimeType == "application/octet-stream"
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
enum PGPArmor {
    enum Kind: Sendable, Equatable {
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

    struct Block: Sendable, Equatable {
        let kind: Kind
        /// Line indexes of the begin and end lines, inclusive.
        let lines: ClosedRange<Int>
        let hasTextOutside: Bool
    }

    /// Complete blocks only: a begin line without its end line is not one.
    /// Lines are compared with trailing spaces, tabs and CR removed; a line
    /// with anything before the dashes (a `> ` quote) is not a header line,
    /// so quoted armor in a reply is not taken for the message's own.
    static func blocks(in text: String) -> [Block] {
        // "\r\n" is one Character in Swift, so split on both forms.
        let lines = text.split(omittingEmptySubsequences: false,
                               whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.trimmingTrailing() }
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            guard let kind = [Kind.message, .signedMessage, .publicKey]
                .first(where: { lines[i] == $0.begin }),
                  let end = lines[(i + 1)...].firstIndex(of: kind.end) else {
                i += 1
                continue
            }
            blocks.append(Block(kind: kind, lines: i...end, hasTextOutside: false))
            i = end + 1
        }
        let covered = Set(blocks.flatMap { Array($0.lines) })
        let outside = lines.indices.contains { !covered.contains($0) && !lines[$0].isEmpty }
        return blocks.map { Block(kind: $0.kind, lines: $0.lines, hasTextOutside: outside) }
    }
}

private extension Substring {
    func trimmingTrailing() -> String {
        var s = self
        while let last = s.last, last == " " || last == "\t" || last == "\r" { s = s.dropLast() }
        return String(s)
    }
}
