import Foundation
import GRDB
import Observation

/// OpenPGP in the running app (step 4B, scope B): the check of the messages
/// the user opens, the passphrases typed this session, and the keys of each
/// account for Settings. Does nothing unless the build turns OpenPGP on
/// (`PGPFeatures.isEnabled`): every entry point returns first.
///
/// What it keeps is in memory only and per session: a message's raw form
/// and decrypted text are never written anywhere (not the database, the
/// search index, a log or a notification) and go when the app quits, the
/// account goes, or the keys change.
@MainActor
@Observable
final class PGPCenter {
    struct Reading: Equatable {
        let security: PGPMessageSecurity
        let indicator: PGPIndicator
        let body: PGPBodyDisplay
        /// The text of an encrypted part decrypted on request.
        let separatePart: String?
    }

    /// By message id (`Message.id`).
    private(set) var readings: [String: Reading] = [:]
    /// Messages checked and found to carry no signed or encrypted OpenPGP
    /// structure (a key attachment, say): shown as any other message.
    private(set) var plain: Set<String> = []
    /// Bumped whenever an account's keys change, so Settings reloads.
    private(set) var keysRevision = 0
    /// The last passphrase tried for an account was wrong.
    private(set) var wrongPassphrase: Set<String> = []

    @ObservationIgnored private var inFlight: Set<String> = []
    let passphrases = PGPPassphrases()
    let secrets: any PGPSecretKeyStorage
    private let database: any DatabaseWriter
    let enabled: Bool
    private let makeEngine: (any PGPKeyStore) -> any OpenPGPEngine

    /// At most this many readings are kept; the oldest go first.
    private static let maxReadings = 64
    @ObservationIgnored private var order: [String] = []

    /// `secrets` and `makeEngine` are for tests; the app uses the Keychain
    /// and this build's engine.
    init(database: any DatabaseWriter, enabled: Bool = PGPFeatures.isEnabled,
         secrets: any PGPSecretKeyStorage = KeychainPGPSecretKeys(),
         makeEngine: @escaping (any PGPKeyStore) -> any OpenPGPEngine = PGPEngines.engine(store:)) {
        self.database = database
        self.enabled = enabled
        self.secrets = secrets
        self.makeEngine = makeEngine
    }

    func engine(accountId: String) -> any OpenPGPEngine {
        makeEngine(DatabasePGPKeyStore(accountId: accountId, database: database,
                                       secrets: secrets, passphrases: passphrases))
    }

    // MARK: - Reading

    /// Checks `message` once, if it looks like OpenPGP: fetches its raw
    /// form and asks the engine. `decryptPart` is the user's explicit
    /// request to decrypt an encrypted part of a larger message.
    /// `fetchRaw` returns the raw message for a Gmail message id
    /// (`GmailClient.getRawMessage`).
    func check(_ message: Message, attachments: [AttachmentRow],
               fetchRaw: (String) async throws -> Data, decryptPart: Bool = false) async {
        guard enabled, PGPDisplay.isCandidate(bodyText: message.bodyText, attachments: attachments,
                                              enabled: enabled) else { return }
        guard decryptPart || (readings[message.id] == nil && !plain.contains(message.id)),
              !inFlight.contains(message.id) else { return }
        inFlight.insert(message.id)
        defer { inFlight.remove(message.id) }
        guard let raw = try? await fetchRaw(message.gmailId) else { return }
        let engine = engine(accountId: message.accountId)
        let checked = await PGPInspection.security(ofRaw: raw, engine: engine, enabled: enabled,
                                                   decryptPartOnRequest: decryptPart)
        guard !Task.isCancelled else { return }
        guard let security = checked else {
            plain.insert(message.id)
            return
        }
        let indicator = PGPSecurityRules.indicator(for: security)
        store(Reading(security: security, indicator: indicator,
                      body: PGPDisplay.body(for: security, indicator: indicator),
                      separatePart: PGPDisplay.separatePart(for: security)),
              for: message.id)
        if case .failed(.passphraseRequired) = security.encryption,
           passphrases.passphrase(accountId: message.accountId) != nil {
            wrongPassphrase.insert(message.accountId)
        } else if case .decrypted = security.encryption {
            wrongPassphrase.remove(message.accountId)
        }
    }

    /// Remote content stays blocked for a message that may be OpenPGP
    /// until it is checked, and after, whenever the rules say so (EFAIL).
    func blocksRemoteContent(_ message: Message, candidate: Bool) -> Bool {
        guard enabled, candidate, !plain.contains(message.id) else { return false }
        return readings[message.id]?.indicator.render.blocksRemoteContent ?? true
    }

    private func store(_ reading: Reading, for id: String) {
        readings[id] = reading
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > Self.maxReadings {
            readings[order.removeFirst()] = nil
        }
    }

    /// The passphrase for `accountId`'s secret keys, for this session. The
    /// messages that asked for it are checked again when next shown.
    func unlock(accountId: String, passphrase: String) {
        guard enabled else { return }
        passphrases.set(Data(passphrase.utf8), accountId: accountId)
        forgetReadings { $0.accountId == accountId }
    }

    // MARK: - Keys (Settings)

    func keys(accountId: String) async throws -> [PGPKeySummary] {
        guard enabled else { return [] }
        return try await engine(accountId: accountId).keys()
    }

    /// Public keys from a file; with `secret`, secret keys (each still under
    /// its own passphrase) and their public halves.
    func importKeys(_ data: Data, accountId: String, secret: Bool) async throws -> [PGPKeySummary] {
        guard enabled else { throw PGPEngineError.unavailable }
        let engine = engine(accountId: accountId)
        let imported = secret ? try await engine.importSecretKeys(data)
                              : try await engine.importKeys(data)
        keysChanged(accountId: accountId)
        return imported
    }

    func delete(_ key: PGPKeyReference, accountId: String) async throws {
        guard enabled else { throw PGPEngineError.unavailable }
        defer { keysChanged(accountId: accountId) }
        try await engine(accountId: accountId).deleteKey(key)
    }

    /// Results read with the old keys no longer stand.
    private func keysChanged(accountId: String) {
        keysRevision &+= 1
        forgetReadings { $0.accountId == accountId }
    }

    // MARK: - Accounts

    /// An account leaves: its passphrase and readings leave memory.
    func forget(accountId: String) {
        passphrases.forget(accountId: accountId)
        wrongPassphrase.remove(accountId)
        forgetReadings { $0.accountId == accountId }
    }

    /// Message ids are `<account>:<gmailId>`.
    private func forgetReadings(where matches: (_ owner: (accountId: String, id: String)) -> Bool) {
        let gone = Set(readings.keys).union(plain).filter { id in
            let account = id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            return matches((account, id))
        }
        for id in gone { readings[id] = nil }
        plain.subtract(gone)
        order.removeAll { gone.contains($0) }
    }

    /// DEC-019, outside the database: the secret keys of a removed account.
    /// Not isolated: called from the account removal's own task.
    nonisolated static func removeSecretKeys(accountId: String) {
        guard PGPFeatures.isEnabled else { return }
        try? KeychainPGPSecretKeys().deleteAll(accountId: accountId)
    }

    /// At launch: secret keys in the Keychain that the database no longer
    /// lists (a removal or delete cut short) are deleted.
    nonisolated static func sweepSecretKeys(database: any DatabaseWriter) async {
        guard PGPFeatures.isEnabled,
              let keep = try? await database.read({ try PGPKeyTable.secretKeyOwners($0) }) else { return }
        try? KeychainPGPSecretKeys().deleteAll(except: keep)
    }
}
