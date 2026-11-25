import Foundation

/// What is known about one message's OpenPGP protection: the engine's
/// results plus how much of the message they cover. Built only by
/// `PGPInspection`, from the engine; never from anything the sender wrote
/// (a subject saying "[signed]", an image of a padlock, a header such as
/// `X-PGP-Signed`).
struct PGPMessageSecurity: Sendable, Equatable {
    enum Encryption: Sendable, Equatable {
        case notEncrypted
        case decrypted(PGPDecryptionResult, coversWholeMessage: Bool)
        case failed(PGPEngineError)
    }

    enum Signature: Sendable, Equatable {
        case unsigned
        case checked([PGPSignatureResult], coversWholeMessage: Bool)
        /// The engine could not check it (no library, malformed data).
        case notChecked(PGPEngineError)
    }

    let encryption: Encryption
    let signature: Signature
    /// The message's `From` header, as received.
    let fromHeader: String
}

/// What the security bar says. Words and colours belong to the interface;
/// these are the decisions it must not get wrong.
struct PGPIndicator: Sendable, Equatable {
    enum Tone: Sendable, Equatable { case none, positive, neutral, warning, error }

    enum Reason: Sendable, Equatable {
        case none
        /// Good signature over the whole message by a key whose user ID is
        /// the `From` address.
        case signed(address: String)
        case encrypted
        case encryptedAndSigned(address: String)
        /// Only part of the message is signed: the rest may be anyone's.
        case partlySigned
        /// Only part of the message is encrypted.
        case partlyEncrypted
        /// Good signature, but by a key with no user ID for the `From`
        /// address (or `From` names more than one mailbox).
        case signerIsNotSender
        case unknownKey(keyID: String)
        case badSignature
        case keyNotValid
        case unsupported
        case notChecked
        case decryptionFailed
        /// Decrypted without an integrity check: content withheld (EFAIL).
        case notIntegrityProtected
    }

    let tone: Tone
    let reason: Reason
    /// The "signed" check mark. Never for part of a message.
    let showsSignedMark: Bool
    /// The padlock. Never for part of a message.
    let showsLock: Bool
    /// Whether decrypted content may be displayed at all.
    let mayShowDecryptedContent: Bool
}

/// How decrypted content is rendered. Fixed, not a preference: the EFAIL
/// attacks (2018) exfiltrate plaintext through remote content and active
/// HTML around or inside a decrypted part.
struct PGPRenderPolicy: Sendable, Equatable {
    let allowsRemoteContent: Bool
    let allowsHTML: Bool
    /// Decrypted text never enters the search index, the AI context, a
    /// notification or a server-side draft.
    let mayLeaveTheMessageView: Bool

    static let decrypted = PGPRenderPolicy(allowsRemoteContent: false, allowsHTML: false,
                                           mayLeaveTheMessageView: false)
}

enum PGPSecurityRules {
    /// The indicator for a message. Pure: the same input always gives the
    /// same answer, and only engine results can raise it above `.none`.
    static func indicator(for security: PGPMessageSecurity) -> PGPIndicator {
        var encryptedWhole = false
        switch security.encryption {
        case .notEncrypted:
            break
        case .failed:
            return PGPIndicator(tone: .error, reason: .decryptionFailed, showsSignedMark: false,
                                showsLock: false, mayShowDecryptedContent: false)
        case .decrypted(let result, let whole):
            guard result.integrityProtected else {
                return PGPIndicator(tone: .error, reason: .notIntegrityProtected,
                                    showsSignedMark: false, showsLock: false,
                                    mayShowDecryptedContent: false)
            }
            guard whole else {
                // Signatures inside a partly encrypted message cover only that
                // part too: nothing positive is shown.
                return PGPIndicator(tone: .warning, reason: .partlyEncrypted,
                                    showsSignedMark: false, showsLock: false,
                                    mayShowDecryptedContent: true)
            }
            encryptedWhole = true
        }

        let verdict = signatureVerdict(security, encryptedWhole: encryptedWhole)
        switch verdict {
        case .none:
            return encryptedWhole
                ? PGPIndicator(tone: .positive, reason: .encrypted, showsSignedMark: false,
                               showsLock: true, mayShowDecryptedContent: true)
                : PGPIndicator(tone: .none, reason: .none, showsSignedMark: false,
                               showsLock: false, mayShowDecryptedContent: true)
        case .signed(let address):
            return PGPIndicator(tone: .positive,
                                reason: encryptedWhole ? .encryptedAndSigned(address: address)
                                                       : .signed(address: address),
                                showsSignedMark: true, showsLock: encryptedWhole,
                                mayShowDecryptedContent: true)
        case .problem(let tone, let reason):
            return PGPIndicator(tone: tone, reason: reason, showsSignedMark: false,
                                showsLock: encryptedWhole, mayShowDecryptedContent: true)
        }
    }

    private enum SignatureVerdict {
        case none
        case signed(address: String)
        case problem(PGPIndicator.Tone, PGPIndicator.Reason)
    }

    private static func signatureVerdict(_ security: PGPMessageSecurity,
                                         encryptedWhole: Bool) -> SignatureVerdict {
        var results: [PGPSignatureResult] = []
        var whole = false
        if case .decrypted(let decryption, _) = security.encryption, !decryption.signatures.isEmpty {
            // A signature inside the encrypted data covers the whole plaintext.
            results = decryption.signatures
            whole = encryptedWhole
        } else {
            switch security.signature {
            case .unsigned: return .none
            case .notChecked: return .problem(.neutral, .notChecked)
            case .checked(let checked, let coversWhole):
                results = checked
                whole = coversWhole
            }
        }

        // Any bad signature is an error, whatever else verified: a message
        // carrying a forged signature next to a good one is not "signed".
        if results.isEmpty || results.contains(.bad) {
            return .problem(.error, .badSignature)
        }
        guard whole else { return .problem(.warning, .partlySigned) }

        let sender = senderAddress(security.fromHeader)
        var sawGoodByOther = false
        for case .good(let signer) in results {
            if let sender, signerAddresses(signer).contains(sender) {
                return .signed(address: sender)
            }
            sawGoodByOther = true
        }
        if sawGoodByOther { return .problem(.warning, .signerIsNotSender) }
        if results.contains(where: { if case .keyNotValid = $0 { return true }; return false }) {
            return .problem(.warning, .keyNotValid)
        }
        for case .unknownKey(let keyID) in results {
            return .problem(.neutral, .unknownKey(keyID: keyID))
        }
        return .problem(.neutral, .unsupported)
    }

    /// The one mailbox in `From`, lowercased; nil when it names none or
    /// several (a signature cannot then vouch for "the sender").
    static func senderAddress(_ fromHeader: String) -> String? {
        let mailboxes = MessageParser.splitAddresses(fromHeader)
        guard mailboxes.count == 1 else { return nil }
        let address = MessageParser.emailAddress(mailboxes[0]).lowercased()
        return address.contains("@") ? address : nil
    }

    /// The addresses in a key's user IDs, lowercased.
    static func signerAddresses(_ signer: PGPKeySummary) -> Set<String> {
        Set(signer.userIDs.map { MessageParser.emailAddress($0).lowercased() }
            .filter { $0.contains("@") })
    }
}
