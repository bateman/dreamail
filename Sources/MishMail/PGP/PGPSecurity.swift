import Foundation

/// What is known about one message's OpenPGP protection: the engine's
/// results plus how much of the message they cover. Built only by
/// `PGPInspection`, from the engine and the raw message; never from anything
/// the sender wrote (a subject saying "[signed]", an image of a padlock, a
/// header such as `X-PGP-Signed`).
///
/// Rule for the step that shows it (S2): a message shown as signed renders
/// only what is parsed from `signedContent` (the exact bytes the signature
/// covers), never Gmail's `format=full` tree, and `fromHeader` comes from
/// the same raw bytes. The signature covers the body part, not the message
/// headers, so the interface says "body signed".
struct PGPMessageSecurity: Sendable, Equatable {
    enum Encryption: Sendable, Equatable {
        case notEncrypted
        case decrypted(PGPDecryptionResult, coversWholeMessage: Bool)
        /// An encrypted part inside a larger message: not decrypted
        /// automatically (EFAIL direct exfiltration), only on the user's
        /// explicit request.
        case notDecrypted
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
    /// The single `From` header of the raw message.
    let fromHeader: String
    /// For a `multipart/signed`: the canonical bytes of the signed part, the
    /// only content that may be shown as signed. Nil otherwise.
    let signedContent: Data?

    init(encryption: Encryption, signature: Signature, fromHeader: String,
         signedContent: Data? = nil) {
        self.encryption = encryption
        self.signature = signature
        self.fromHeader = fromHeader
        self.signedContent = signedContent
    }
}

/// How the message view must treat content, decided with the indicator so a
/// caller cannot take one without the other. Decrypted content is always
/// plain text (no HTML), and decrypted text never leaves the message view:
/// not the search index, the AI context, a notification or a server draft.
struct PGPRenderPolicy: Sendable, Equatable {
    enum DecryptedContent: Sendable, Equatable {
        /// Nothing encrypted.
        case none
        /// Shown in place, as plain text.
        case inline
        /// An encrypted part of a larger message, decrypted on request: shown
        /// apart from the rest, as plain text.
        case separateView
        /// An encrypted part of a larger message, not decrypted: the user
        /// may ask for it explicitly.
        case onRequest
        /// Not shown at all (decryption failed or was not integrity-checked).
        case withheld
    }

    let decryptedContent: DecryptedContent
    /// Remote content (images, styles) is blocked for the whole message,
    /// whatever the user's setting: EFAIL exfiltrates plaintext through it.
    let blocksRemoteContent: Bool

    static let plain = PGPRenderPolicy(decryptedContent: .none, blocksRemoteContent: false)
}

/// What the security bar says. Words and colours belong to the interface;
/// these are the decisions it must not get wrong.
struct PGPIndicator: Sendable, Equatable {
    enum Tone: Sendable, Equatable { case none, positive, neutral, warning, error }

    enum Reason: Sendable, Equatable {
        case none
        /// Good signature over the whole body by a key with a user ID for the
        /// `From` address. Interface wording: "body signed" (headers are not
        /// covered).
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
        /// Encrypted, but this build has no OpenPGP library.
        case decryptionUnavailable
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
    let render: PGPRenderPolicy
}

enum PGPSecurityRules {
    /// The indicator for a message. Pure: the same input always gives the
    /// same answer, and only engine results can raise it above `.none`.
    static func indicator(for security: PGPMessageSecurity) -> PGPIndicator {
        var encryptedWhole = false
        var render = PGPRenderPolicy.plain
        switch security.encryption {
        case .notEncrypted:
            break
        case .failed(let error):
            let (tone, reason): (PGPIndicator.Tone, PGPIndicator.Reason)
            switch error {
            case .unavailable: (tone, reason) = (.neutral, .decryptionUnavailable)
            case .notIntegrityProtected: (tone, reason) = (.error, .notIntegrityProtected)
            default: (tone, reason) = (.error, .decryptionFailed)
            }
            return PGPIndicator(tone: tone, reason: reason, showsSignedMark: false, showsLock: false,
                                render: PGPRenderPolicy(decryptedContent: .withheld,
                                                        blocksRemoteContent: true))
        case .notDecrypted:
            return partlyEncrypted(.onRequest)
        case .decrypted(_, let whole):
            // Signatures inside a partly encrypted message cover only that
            // part too: nothing positive is shown.
            guard whole else { return partlyEncrypted(.separateView) }
            encryptedWhole = true
            render = PGPRenderPolicy(decryptedContent: .inline, blocksRemoteContent: true)
        }

        switch signatureVerdict(security, encryptedWhole: encryptedWhole) {
        case .none:
            return encryptedWhole
                ? PGPIndicator(tone: .positive, reason: .encrypted, showsSignedMark: false,
                               showsLock: true, render: render)
                : PGPIndicator(tone: .none, reason: .none, showsSignedMark: false,
                               showsLock: false, render: render)
        case .signed(let address):
            return PGPIndicator(tone: .positive,
                                reason: encryptedWhole ? .encryptedAndSigned(address: address)
                                                       : .signed(address: address),
                                showsSignedMark: true, showsLock: encryptedWhole, render: render)
        case .problem(let tone, let reason):
            return PGPIndicator(tone: tone, reason: reason, showsSignedMark: false,
                                showsLock: encryptedWhole, render: render)
        }
    }

    private static func partlyEncrypted(_ content: PGPRenderPolicy.DecryptedContent) -> PGPIndicator {
        PGPIndicator(tone: .warning, reason: .partlyEncrypted, showsSignedMark: false,
                     showsLock: false,
                     render: PGPRenderPolicy(decryptedContent: content, blocksRemoteContent: true))
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
    ///
    /// shortcut: any user ID on an imported key counts, with no certification
    /// or web of trust. That is why the import screen must show the
    /// fingerprint and every user ID as unverified, and why the engine leaves
    /// revoked user IDs out of `PGPKeySummary.userIDs`.
    static func signerAddresses(_ signer: PGPKeySummary) -> Set<String> {
        Set(signer.userIDs.map { MessageParser.emailAddress($0).lowercased() }
            .filter { $0.contains("@") })
    }
}
