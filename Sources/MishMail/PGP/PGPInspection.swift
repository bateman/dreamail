import Foundation

/// The bytes an OpenPGP/MIME entity hands to the engine, cut from the raw
/// message.
struct PGPMIMEPayload: Sendable, Equatable {
    /// For `multipart/signed`: the first body part, headers included, from
    /// the byte after its delimiter line to the byte before the line break
    /// that precedes the next delimiter, in canonical CRLF form (RFC 3156
    /// §5). For `multipart/encrypted`: empty.
    let signedData: Data
    /// The signature (`multipart/signed`) or the encrypted payload
    /// (`multipart/encrypted`), its transfer encoding undone.
    let pgpData: Data
    /// `micalg` of a `multipart/signed`, lowercased (e.g. `pgp-sha256`).
    let micalg: String?
}

enum PGPInspection {
    /// OpenPGP findings in a raw message. Empty with the switch off, and
    /// the message is not even parsed.
    static func findings(inRaw raw: Data, enabled: Bool) -> [PGPLocatedFinding] {
        guard enabled else { return [] }
        let root = RawMIME.parse(raw)
        return PGPStructure.findings(in: MIMEOutline(raw: root, in: raw), enabled: true)
    }

    /// OpenPGP findings in Gmail's `format=full` payload: enough to decide
    /// that a message needs its raw form, never enough to verify it.
    static func findings(inGmail payload: GMessage.Part?, enabled: Bool) -> [PGPLocatedFinding] {
        guard enabled, let payload else { return [] }
        return PGPStructure.findings(in: MIMEOutline(gmail: payload), enabled: true)
    }

    /// The entity at `path` in a parsed raw message.
    static func part(at path: [Int], in root: RawMIMEPart) -> RawMIMEPart? {
        var node = root
        for index in path {
            guard node.children.indices.contains(index) else { return nil }
            node = node.children[index]
        }
        return node
    }

    /// The engine inputs of the `multipart/signed` or `multipart/encrypted`
    /// at `path`. Nil when that entity is not well-formed OpenPGP/MIME.
    static func payload(at path: [Int], inRaw raw: Data) -> PGPMIMEPayload? {
        let root = RawMIME.parse(raw)
        guard let node = part(at: path, in: root) else { return nil }
        let outline = MIMEOutline(raw: node, in: raw)
        if node.contentType.mimeType == "multipart/signed", PGPStructure.isMIMESigned(outline) {
            let signed = RawMIME.bytes(raw, node.children[0].range)
            return PGPMIMEPayload(
                signedData: RawMIME.canonicalCRLF(signed),
                pgpData: RawMIME.decodedBody(node.children[1], in: raw),
                micalg: node.contentType.parameters["micalg"]?.lowercased())
        }
        if node.contentType.mimeType == "multipart/encrypted", PGPStructure.isMIMEEncrypted(outline) {
            return PGPMIMEPayload(signedData: Data(),
                                  pgpData: RawMIME.decodedBody(node.children[1], in: raw),
                                  micalg: nil)
        }
        return nil
    }

    /// Checks the first OpenPGP/MIME entity of a raw message with `engine`
    /// and says what is known. Nil with the switch off (the engine is not
    /// called) and for a message with no OpenPGP/MIME entity.
    static func security(ofRaw raw: Data, fromHeader: String, engine: any OpenPGPEngine,
                         enabled: Bool) async -> PGPMessageSecurity? {
        guard enabled else { return nil }
        let findings = findings(inRaw: raw, enabled: true)
        guard let first = findings.first(where: {
            $0.finding == .mimeSigned || $0.finding == .mimeEncrypted
        }) else {
            if findings.contains(where: { $0.finding == .malformedMIME }) {
                return PGPMessageSecurity(encryption: .notEncrypted,
                                          signature: .notChecked(.malformed),
                                          fromHeader: fromHeader)
            }
            return nil
        }
        guard let payload = payload(at: first.path, inRaw: raw) else { return nil }
        let whole = first.coversWholeMessage

        if first.finding == .mimeSigned {
            do {
                let results = try await engine.verifyDetached(signedData: payload.signedData,
                                                              signature: payload.pgpData)
                return PGPMessageSecurity(encryption: .notEncrypted,
                                          signature: .checked(results, coversWholeMessage: whole),
                                          fromHeader: fromHeader)
            } catch {
                return PGPMessageSecurity(encryption: .notEncrypted,
                                          signature: .notChecked(engineError(error)),
                                          fromHeader: fromHeader)
            }
        }
        do {
            let result = try await engine.decrypt(payload.pgpData)
            return PGPMessageSecurity(encryption: .decrypted(result, coversWholeMessage: whole),
                                      signature: .unsigned, fromHeader: fromHeader)
        } catch {
            return PGPMessageSecurity(encryption: .failed(engineError(error)),
                                      signature: .unsigned, fromHeader: fromHeader)
        }
    }

    private static func engineError(_ error: Error) -> PGPEngineError {
        (error as? PGPEngineError) ?? .malformed
    }
}
