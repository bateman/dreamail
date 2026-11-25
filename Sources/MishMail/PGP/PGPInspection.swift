import Foundation

/// The entry points that read a message. Each takes the build switch as a
/// parameter and, with it off, returns before parsing anything or calling
/// an engine.
enum PGPInspection {
    /// OpenPGP findings in a raw message.
    static func findings(inRaw raw: Data, enabled: Bool) -> [PGPLocatedFinding] {
        guard enabled else { return [] }
        return findings(RawMIME.parse(raw), raw)
    }

    /// OpenPGP findings in Gmail's `format=full` payload: enough to decide
    /// that a message needs its raw form, never enough to verify it or to
    /// show it as signed.
    static func findings(inGmail payload: GMessage.Part?, enabled: Bool) -> [PGPLocatedFinding] {
        guard enabled, let payload else { return [] }
        return PGPStructure.findings(in: MIMEOutline(gmail: payload), enabled: true)
    }

    /// Checks the first OpenPGP/MIME entity of a raw message with `engine`
    /// and says what is known; with none, the first cleartext-signed text
    /// part. Nil with the switch off (nothing is parsed and the engine is
    /// not called) and for a message with neither.
    ///
    /// `From` is read from the same raw bytes; a message with more than one
    /// `From` header is not checked. An encrypted part inside a larger
    /// message is decrypted only when `decryptPartOnRequest` is true, which
    /// the caller sets only on the user's explicit action.
    static func security(ofRaw raw: Data, engine: any OpenPGPEngine, enabled: Bool,
                         decryptPartOnRequest: Bool = false) async -> PGPMessageSecurity? {
        guard enabled else { return nil }
        let root = RawMIME.parse(raw)
        let found = findings(root, raw)
        let froms = root.headers.filter { $0.name == "from" }
        let fromHeader = froms.first?.value ?? ""

        guard let first = found.first(where: {
            $0.finding == .mimeSigned || $0.finding == .mimeEncrypted
        }) else {
            if found.contains(where: { $0.finding == .malformedMIME }) {
                return PGPMessageSecurity(encryption: .notEncrypted, signature: .notChecked(.malformed),
                                          fromHeader: fromHeader)
            }
            guard let inline = found.first(where: { $0.finding == .inlineSigned }) else { return nil }
            return await cleartext(inline, root: root, raw: raw, froms: froms.count,
                                   fromHeader: fromHeader, engine: engine)
        }
        guard froms.count == 1 else {
            return PGPMessageSecurity(encryption: .notEncrypted, signature: .notChecked(.malformed),
                                      fromHeader: fromHeader)
        }
        guard let node = part(at: first.path, in: root), node.children.count == 2 else { return nil }
        let whole = first.coversWholeMessage
        let pgpData = RawMIME.decodedBody(node.children[1], in: raw)

        if first.finding == .mimeSigned {
            let signed = RawMIME.canonicalCRLF(RawMIME.bytes(raw, node.children[0].range))
            let signature: PGPMessageSecurity.Signature
            do {
                let results = try await engine.verifyDetached(signedData: signed, signature: pgpData)
                signature = .checked(results, coversWholeMessage: whole)
            } catch {
                signature = .notChecked(engineError(error))
            }
            return PGPMessageSecurity(encryption: .notEncrypted, signature: signature,
                                      fromHeader: fromHeader, signedContent: signed)
        }

        guard whole || decryptPartOnRequest else {
            return PGPMessageSecurity(encryption: .notDecrypted, signature: .unsigned,
                                      fromHeader: fromHeader)
        }
        do {
            let result = try await engine.decrypt(pgpData)
            return PGPMessageSecurity(encryption: .decrypted(result, coversWholeMessage: whole),
                                      signature: .unsigned, fromHeader: fromHeader)
        } catch {
            return PGPMessageSecurity(encryption: .failed(engineError(error)),
                                      signature: .unsigned, fromHeader: fromHeader)
        }
    }

    /// A cleartext-signed text part (`BEGIN PGP SIGNED MESSAGE`). Only the
    /// text the engine returns may be shown as signed (`signedText`).
    private static func cleartext(_ inline: PGPLocatedFinding, root: RawMIMEPart, raw: Data,
                                  froms: Int, fromHeader: String,
                                  engine: any OpenPGPEngine) async -> PGPMessageSecurity? {
        guard froms == 1 else {
            return PGPMessageSecurity(encryption: .notEncrypted, signature: .notChecked(.malformed),
                                      fromHeader: fromHeader)
        }
        guard let node = part(at: inline.path, in: root) else { return nil }
        let text = RawMIME.decodedBody(node, in: raw)
        do {
            let result = try await engine.verifyCleartext(text)
            return PGPMessageSecurity(
                encryption: .notEncrypted,
                signature: .checked(result.signatures, coversWholeMessage: inline.coversWholeMessage),
                fromHeader: fromHeader, signedText: result.signedText)
        } catch {
            return PGPMessageSecurity(encryption: .notEncrypted, signature: .notChecked(engineError(error)),
                                      fromHeader: fromHeader)
        }
    }

    private static func findings(_ root: RawMIMEPart, _ raw: Data) -> [PGPLocatedFinding] {
        PGPStructure.findings(in: MIMEOutline(raw: root, in: raw), enabled: true)
    }

    private static func part(at path: [Int], in root: RawMIMEPart) -> RawMIMEPart? {
        var node = root
        for index in path {
            guard node.children.indices.contains(index) else { return nil }
            node = node.children[index]
        }
        return node
    }

    /// Anything that is not the engine's own answer (the Keychain, the
    /// database) says nothing about the message.
    private static func engineError(_ error: Error) -> PGPEngineError {
        (error as? PGPEngineError) ?? .keysUnavailable
    }
}
