import Foundation

/// What the message view shows for a message's body once its OpenPGP state
/// is known. Decided here, from the engine's results and the indicator, so
/// the view cannot show more than the rules allow (S2, EFAIL).
enum PGPBodyDisplay: Sendable, Equatable {
    /// The body as for any message.
    case original
    /// This text in place of the body, as plain text (never HTML): the
    /// decrypted text, or the exact text a good signature covers.
    case text(String)
    /// A notice in place of the body. Armor is never shown as if it were
    /// the message.
    case notice(PGPBodyNotice)
}

enum PGPBodyNotice: Sendable, Equatable {
    case unavailable, noSecretKey, passphraseRequired, notIntegrityProtected
    /// Above the engine's size limit.
    case tooLarge
    /// The engine reported an unsupported or unreadable format (GnuPG's own
    /// OCB packet comes back as malformed today). Unauthenticated: anyone
    /// on the path can produce it by editing unprotected octets, so it reads
    /// exactly like a failed integrity check, apart from the detail line.
    case unsupportedFormat
    /// Decrypted or signed, but there is no text part to show.
    case noReadableText
    /// More text than the view shows (`PGPDisplay.maxShownBytes`).
    case tooLongToShow
    /// The keys could not be read just now; checked again at the next open.
    case cannotCheckNow

    /// The headline. Every failure an attacker could cause says the same:
    /// nothing reads as more harmless than a failed integrity check (no
    /// "update the app", no "ask for it unencrypted").
    var text: String {
        switch self {
        case .unavailable:
            return "This message is encrypted. This version of MishMail can’t decrypt it."
        case .noSecretKey:
            return "This message is encrypted, and none of your keys can decrypt it."
        case .passphraseRequired:
            return "This message is encrypted. Enter the passphrase of your key to read it."
        case .notIntegrityProtected, .tooLarge, .unsupportedFormat:
            return "This message could not be decrypted."
        case .noReadableText:
            return "This message has no text to show."
        case .tooLongToShow:
            return "This message is too long to show here."
        case .cannotCheckNow:
            return "MishMail can’t check this message right now. It will try again when you open it."
        }
    }

    /// The technical reason, shown smaller under the headline.
    var detail: String? {
        switch self {
        case .unavailable, .noSecretKey, .passphraseRequired, .noReadableText, .tooLongToShow, .cannotCheckNow: return nil
        case .notIntegrityProtected:
            return "Integrity check failed or missing: the encrypted data may have been changed, so nothing of it is shown."
        case .tooLarge: return "The encrypted data is larger than the decryption limit."
        case .unsupportedFormat: return "The decryption engine reported an unsupported or damaged format."
        }
    }
}

/// One signature as the details popover lists it.
struct PGPSignatureLine: Sendable, Equatable {
    enum Status: String, Sendable, Equatable {
        case valid = "Valid"
        case invalid = "Invalid"
        case unknownKey = "Can’t verify: unknown key"
        case expired = "Key expired"
        case revoked = "Key revoked"
        case unsupported = "Can’t verify: unsupported"
    }

    let status: Status
    /// The signer's user IDs, all unverified; empty when the key is unknown.
    let userIDs: [String]
    /// Full fingerprint, or the key ID the signature names.
    let keyIdentifier: String
}

enum PGPDisplay {
    /// The most text shown in place of a body. The library releases up to
    /// 64 MiB of plaintext; one SwiftUI `Text` of that hangs the app.
    static let maxShownBytes = 1024 * 1024

    /// The signed mark only when the address the signature vouches for is
    /// the one the message card shows (`Message.fromHeader`, parsed by
    /// Gmail), not just the one read from the raw header: a crafted `From`
    /// (encoded words, comments, two mailboxes) could make them differ.
    /// Otherwise the signer is not the sender, as far as the user can see.
    static func bound(_ indicator: PGPIndicator, displayedFrom: String) -> PGPIndicator {
        let vouched: String
        switch indicator.reason {
        case .signed(let address), .encryptedAndSigned(let address): vouched = address
        default: return indicator
        }
        let shown = MessageParser.splitAddresses(displayedFrom)
        guard shown.count == 1,
              MessageParser.emailAddress(shown[0]).lowercased() == vouched.lowercased() else {
            return PGPIndicator(tone: .warning, reason: .signerIsNotSender, showsSignedMark: false,
                                showsLock: indicator.showsLock, render: indicator.render)
        }
        return indicator
    }

    private enum Readable {
        case text(String), tooLong, none
    }

    /// Text in place of the body, or the notice that it is too long.
    private static func shown(_ readable: Readable) -> PGPBodyDisplay? {
        switch readable {
        case .text(let text): return text.utf8.count > maxShownBytes ? .notice(.tooLongToShow) : .text(text)
        case .tooLong: return .notice(.tooLongToShow)
        case .none: return nil
        }
    }

    /// Gmail-style one-line summary next to the sender, with an SF Symbol.
    /// Nil when there is nothing to show.
    static func summary(_ indicator: PGPIndicator) -> (title: String, symbol: String)? {
        switch indicator.reason {
        case .none: return nil
        case .signed(let address): return ("Body signed by \(address)", "checkmark.seal.fill")
        case .encrypted: return ("Encrypted", "lock.fill")
        case .encryptedAndSigned(let address):
            return ("Encrypted, body signed by \(address)", "lock.fill")
        case .partlySigned: return ("Only part of this message is signed", "exclamationmark.triangle.fill")
        case .partlyEncrypted:
            return ("Only part of this message is encrypted", "exclamationmark.triangle.fill")
        case .signerIsNotSender: return ("Signed, but not by the sender", "exclamationmark.triangle.fill")
        case .unknownKey: return ("Can’t verify the signature: unknown key", "questionmark.circle")
        case .badSignature: return ("Invalid signature", "xmark.seal.fill")
        case .keyNotValid: return ("Signed with an expired or revoked key", "exclamationmark.triangle.fill")
        case .unsupported, .notChecked: return ("Can’t verify the signature", "questionmark.circle")
        case .decryptionUnavailable: return ("Encrypted", "lock")
        case .decryptionFailed, .notIntegrityProtected: return ("This message could not be decrypted", "lock.slash")
        }
    }

    /// What replaces the body. Only a positive indicator ever replaces it
    /// with content, and only with what the engine returned.
    static func body(for security: PGPMessageSecurity, indicator: PGPIndicator) -> PGPBodyDisplay {
        switch security.encryption {
        case .failed(let error):
            switch error {
            case .unavailable: return .notice(.unavailable)
            case .noSecretKey: return .notice(.noSecretKey)
            case .passphraseRequired: return .notice(.passphraseRequired)
            case .notIntegrityProtected: return .notice(.notIntegrityProtected)
            case .malformed, .unsupported: return .notice(.unsupportedFormat)
            case .tooLarge: return .notice(.tooLarge)
            // Never cached as a reading (`PGPCenter.check`); here only for
            // completeness.
            case .keysUnavailable: return .notice(.cannotCheckNow)
            }
        case .decrypted(let result, let whole):
            guard whole, indicator.render.decryptedContent == .inline else { return .original }
            return shown(readable(result.plaintext)) ?? .notice(.noReadableText)
        case .notDecrypted:
            return .original
        case .notEncrypted:
            guard indicator.showsSignedMark else { return .original }
            if let text = security.signedText {
                guard text.count <= maxShownBytes else { return .notice(.tooLongToShow) }
                return .text(decode(text, contentType: nil))
            }
            if let content = security.signedContent, let display = shown(readable(content)) {
                return display
            }
            // Signed, but nothing readable in the signed part: the body as
            // Gmail shows it is not what was signed, so it is not shown.
            return .notice(.noReadableText)
        }
    }

    /// The decrypted text of an encrypted part inside a larger message,
    /// decrypted on request: shown apart from the rest (`separateView`).
    static func separatePart(for security: PGPMessageSecurity) -> String? {
        guard case .decrypted(let result, false) = security.encryption else { return nil }
        switch shown(readable(result.plaintext)) {
        case .text(let text)?: return text
        case .notice(let notice)?: return notice.text
        default: return nil
        }
    }

    /// The signatures, for the details popover.
    static func signatureLines(_ security: PGPMessageSecurity) -> [PGPSignatureLine] {
        var results: [PGPSignatureResult] = []
        if case .decrypted(let decryption, _) = security.encryption {
            results = decryption.signatures
        }
        if results.isEmpty, case .checked(let checked, _) = security.signature {
            results = checked
        }
        return results.map { result in
            switch result {
            case .good(let signer):
                return PGPSignatureLine(status: .valid, userIDs: signer.userIDs,
                                        keyIdentifier: signer.key.fingerprint)
            case .keyNotValid(let signer):
                return PGPSignatureLine(status: signer.validity == .revoked ? .revoked : .expired,
                                        userIDs: signer.userIDs, keyIdentifier: signer.key.fingerprint)
            case .bad:
                return PGPSignatureLine(status: .invalid, userIDs: [], keyIdentifier: "")
            case .unknownKey(let keyID):
                return PGPSignatureLine(status: .unknownKey, userIDs: [], keyIdentifier: keyID)
            case .unsupported:
                return PGPSignatureLine(status: .unsupported, userIDs: [], keyIdentifier: "")
            }
        }
    }

    /// Groups of four, as key tools print fingerprints.
    static func grouped(_ fingerprint: String) -> String {
        stride(from: 0, to: fingerprint.count, by: 4).map { start in
            let from = fingerprint.index(fingerprint.startIndex, offsetBy: start)
            let to = fingerprint.index(from, offsetBy: 4, limitedBy: fingerprint.endIndex)
                ?? fingerprint.endIndex
            return String(fingerprint[from..<to])
        }.joined(separator: " ")
    }

    /// The text of a MIME entity (a decrypted message, a signed part): the
    /// first `text/plain` part that is not an attachment, else the first
    /// `text/html` part turned into text. Never HTML. Nil when there is none.
    static func readableText(ofEntity data: Data) -> String? {
        if case .text(let text) = readable(data) { return text }
        return nil
    }

    private static func readable(_ data: Data) -> Readable {
        let root = RawMIME.parse(data)
        if let plain = firstLeaf(root, type: "text/plain") {
            let body = RawMIME.decodedBody(plain, in: data)
            guard body.count <= 4 * maxShownBytes else { return .tooLong }
            return .text(decode(body, contentType: plain.header("content-type")))
        }
        if let html = firstLeaf(root, type: "text/html") {
            let body = RawMIME.decodedBody(html, in: data)
            // Decoding and regex stripping cost time: text far above what is
            // shown is not processed at all.
            guard body.count <= 4 * maxShownBytes else { return .tooLong }
            return .text(MessageParser.stripHTML(decode(body, contentType: html.header("content-type"))))
        }
        return .none
    }

    private static func firstLeaf(_ part: RawMIMEPart, type: String) -> RawMIMEPart? {
        if part.children.isEmpty {
            let attachment = part.header("content-disposition")?.lowercased()
                .trimmingCharacters(in: .whitespaces).hasPrefix("attachment") ?? false
            return part.contentType.mimeType == type && !attachment ? part : nil
        }
        for child in part.children {
            if let found = firstLeaf(child, type: type) { return found }
        }
        return nil
    }

    private static func decode(_ data: Data, contentType: String?) -> String {
        MessageParser.decodeText(data, contentType: contentType) ?? String(decoding: data, as: UTF8.self)
    }

    /// Whether a stored message may carry OpenPGP and is worth fetching in
    /// raw form: an OpenPGP attachment by type or name, or an armor header
    /// line in its text. A cheap first look only; `PGPInspection` decides.
    static func isCandidate(bodyText: String, attachments: [AttachmentRow], enabled: Bool) -> Bool {
        guard enabled else { return false }
        if bodyText.contains("-----BEGIN PGP SIGNED MESSAGE-----")
            || bodyText.contains("-----BEGIN PGP MESSAGE-----") {
            return true
        }
        return attachments.contains { row in
            let type = row.mimeType.lowercased()
            let name = row.filename.lowercased()
            return type == PGPStructure.signatureProtocol || type == PGPStructure.encryptedProtocol
                || [".asc", ".sig", ".gpg", ".pgp"].contains { name.hasSuffix($0) }
        }
    }

    /// A user ID as text that cannot mislead: control characters (a
    /// newline that fakes a second user ID) and bidirectional formatting
    /// characters (which reorder what is shown) are written as visible
    /// `U+XXXX` escapes.
    static func safeUserID(_ userID: String) -> String {
        var out = ""
        for scalar in userID.unicodeScalars {
            let bidi = (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
                || [0x200E, 0x200F, 0x061C].contains(scalar.value)
            if scalar.properties.generalCategory == .control || bidi {
                out += String(format: "\u{27E8}U+%04X\u{27E9}", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// For each key about to be imported, the addresses of its user IDs
    /// that another stored key of the account already claims: the import
    /// screen flags them, since a signature by either key would show that
    /// address as signed.
    static func addressesClaimedElsewhere(_ incoming: [PGPKeySummary],
                                          stored: [PGPKeySummary]) -> [PGPKeyReference: [String]] {
        var out: [PGPKeyReference: [String]] = [:]
        for key in incoming {
            let mine = PGPSecurityRules.signerAddresses(key)
            // Other stored keys, and the other keys of the same file.
            let others = (stored + incoming).filter { $0.key != key.key }
                .reduce(into: Set<String>()) { $0.formUnion(PGPSecurityRules.signerAddresses($1)) }
            let clash = mine.intersection(others).sorted()
            if !clash.isEmpty { out[key.key] = clash }
        }
        return out
    }
}
