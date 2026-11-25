import AppKit
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
/// account goes, the keys change, or the screen locks or the Mac sleeps.
@MainActor
@Observable
final class PGPCenter {
    /// What the view needs of a checked message, and nothing more: the
    /// plaintext, raw signed bytes and the rest of `PGPMessageSecurity` are
    /// dropped once this is built.
    struct Reading: Equatable, Sendable {
        let indicator: PGPIndicator
        let body: PGPBodyDisplay
        /// The text of an encrypted part decrypted on request.
        let separatePart: String?
        let signatures: [PGPSignatureLine]

        /// Built off the main actor: the plaintext can be tens of MiB.
        /// `displayedFrom` is the From the message card shows: the signed
        /// mark is given only when it names the address the signature
        /// vouches for.
        static func build(_ security: PGPMessageSecurity, displayedFrom: String) -> Reading {
            let indicator = PGPDisplay.bound(PGPSecurityRules.indicator(for: security),
                                             displayedFrom: displayedFrom)
            return Reading(indicator: indicator,
                           body: PGPDisplay.body(for: security, indicator: indicator),
                           separatePart: PGPDisplay.separatePart(for: security),
                           signatures: PGPDisplay.signatureLines(security))
        }
    }

    /// Settings → OpenPGP keys remembers the account it shows here.
    nonisolated static let settingsAccountKey = "settings.openPGP.account"
    /// A key file above this is refused before it is read in full.
    nonisolated static let maxKeyFileBytes = 1024 * 1024
    nonisolated static let maxKeysPerFile = 50

    /// By message id (`Message.id`).
    private(set) var readings: [String: Reading] = [:]
    /// Messages checked and found to carry no signed or encrypted OpenPGP
    /// structure (a key attachment, say): shown as any other message.
    private(set) var plain: Set<String> = []
    /// Messages that could not be checked just now (the raw message could
    /// not be fetched, the keys could not be read): a neutral "can't check"
    /// indicator, remote content still blocked, and another try at the next
    /// open. Never cached as a verdict.
    private(set) var uncheckable: Set<String> = []
    /// Bumped when readings are dropped because keys, a passphrase or the
    /// lock state changed: open cards check again. Not on eviction, so a
    /// pane with more candidates than the cache holds cannot loop.
    private(set) var generation = 0
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
    private let defaults: UserDefaults
    private let observers = ObserverTokens()

    /// At most this many readings are kept; the oldest go first. Each
    /// holds at most `PGPDisplay.maxShownBytes` of text.
    private static let maxReadings = 256
    @ObservationIgnored private var order: [String] = []
    /// `isCandidate` per message, so the body scan runs once, not on every
    /// render of the card.
    @ObservationIgnored private var candidates: [String: Bool] = [:]

    /// `secrets` and `makeEngine` are for tests; the app uses the Keychain
    /// and this build's engine.
    init(database: any DatabaseWriter, enabled: Bool = PGPFeatures.isEnabled,
         secrets: any PGPSecretKeyStorage = KeychainPGPSecretKeys(),
         defaults: UserDefaults = .standard,
         makeEngine: @escaping (any PGPKeyStore) -> any OpenPGPEngine = PGPEngines.engine(store:)) {
        self.database = database
        self.enabled = enabled
        self.secrets = secrets
        self.defaults = defaults
        self.makeEngine = makeEngine
        if enabled { forgetOnLockAndSleep() }
    }

    /// Passphrases and decrypted text leave memory when the screen locks or
    /// the Mac sleeps.
    private func forgetOnLockAndSleep() {
        let forget: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.lockedOrAsleep() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.add(workspace, workspace.addObserver(forName: name, object: nil, queue: .main, using: forget))
        }
        let distributed = DistributedNotificationCenter.default()
        observers.add(distributed, distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: forget))
    }

    func lockedOrAsleep() {
        passphrases.forgetAll()
        wrongPassphrase = []
        readings = [:]
        order = []
        generation &+= 1
    }

    /// Whether `message` may carry OpenPGP (`PGPDisplay.isCandidate`),
    /// scanned once per message and body. False with the switch off.
    func isCandidate(_ message: Message, attachments: [AttachmentRow]) -> Bool {
        guard enabled else { return false }
        let key = "\(message.id)|\(message.bodyText.utf8.count)|\(attachments.count)"
        if let known = candidates[key] { return known }
        if candidates.count > 4096 { candidates = [:] }
        let found = PGPDisplay.isCandidate(bodyText: message.bodyText, attachments: attachments, enabled: true)
        candidates[key] = found
        return found
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
        guard enabled, isCandidate(message, attachments: attachments) else { return }
        guard decryptPart || (readings[message.id] == nil && !plain.contains(message.id)),
              !inFlight.contains(message.id) else { return }
        inFlight.insert(message.id)
        defer { inFlight.remove(message.id) }
        guard let raw = try? await fetchRaw(message.gmailId) else {
            uncheckable.insert(message.id)
            return
        }
        let engine = engine(accountId: message.accountId)
        let checked = await PGPInspection.security(ofRaw: raw, engine: engine, enabled: enabled,
                                                   decryptPartOnRequest: decryptPart)
        guard !Task.isCancelled else { return }
        guard let security = checked else {
            uncheckable.remove(message.id)
            plain.insert(message.id)
            return
        }
        // The keys could not be read: no verdict, try again later.
        if case .failed(.keysUnavailable) = security.encryption {
            uncheckable.insert(message.id)
            return
        }
        if case .notChecked(.keysUnavailable) = security.signature {
            uncheckable.insert(message.id)
            return
        }
        uncheckable.remove(message.id)
        let displayedFrom = message.fromHeader
        let reading = await Task.detached(priority: .userInitiated) {
            Reading.build(security, displayedFrom: displayedFrom)
        }.value
        guard !Task.isCancelled else { return }
        store(reading, for: message.id)
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

    /// What a key file holds, stored nowhere, for the confirmation screen.
    /// Bounded: at most `maxKeyFileBytes` and `maxKeysPerFile`.
    func inspect(_ data: Data, accountId: String) async throws -> [PGPKeySummary] {
        guard enabled else { throw PGPEngineError.unavailable }
        guard data.count <= Self.maxKeyFileBytes else { throw PGPEngineError.tooLarge }
        let keys = try await engine(accountId: accountId).inspectKeys(data)
        guard keys.count <= Self.maxKeysPerFile else { throw PGPEngineError.tooLarge }
        return keys
    }

    /// Public keys from a file; with `secret`, secret keys (each still under
    /// its own passphrase) and their public halves. Only after the user
    /// confirmed what `inspect` showed; the same limits apply.
    func importKeys(_ data: Data, accountId: String, secret: Bool) async throws -> [PGPKeySummary] {
        _ = try await inspect(data, accountId: accountId)
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

    /// An account leaves: its passphrase and readings leave memory, and
    /// Settings forgets it was the account shown. Whatever the switch says.
    func forget(accountId: String) {
        if defaults.string(forKey: Self.settingsAccountKey) == accountId {
            defaults.removeObject(forKey: Self.settingsAccountKey)
        }
        passphrases.forget(accountId: accountId)
        wrongPassphrase.remove(accountId)
        forgetReadings { $0.accountId == accountId }
    }

    /// Message ids are `<account>:<gmailId>`.
    private func forgetReadings(where matches: (_ owner: (accountId: String, id: String)) -> Bool) {
        let gone = Set(readings.keys).union(plain).union(uncheckable).filter { id in
            let account = id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            return matches((account, id))
        }
        for id in gone { readings[id] = nil }
        plain.subtract(gone)
        uncheckable.subtract(gone)
        order.removeAll { gone.contains($0) }
        generation &+= 1
    }

    /// DEC-019, outside the database: the secret keys of a removed account,
    /// whatever the switch says (a build with it off still removes what a
    /// build with it on stored). Not isolated: called from the account
    /// removal's own task.
    nonisolated static func removeSecretKeys(accountId: String,
                                             secrets: any PGPSecretKeyStorage = KeychainPGPSecretKeys()) {
        try? secrets.deleteAll(accountId: accountId)
    }

    /// At launch, whatever the switch says: secret keys in the Keychain that
    /// the database no longer lists (a removal or delete cut short) are
    /// deleted. A database that cannot be read sweeps nothing.
    nonisolated static func sweepSecretKeys(database: any DatabaseWriter,
                                            secrets: any PGPSecretKeyStorage = KeychainPGPSecretKeys()) async {
        _ = try? await PGPSecretKeyLock.shared.run {
            let keep = try await database.read { try PGPKeyTable.secretKeyOwners($0) }
            try secrets.deleteAll(except: keep)
        }
    }
}

/// Notification observers, removed when their owner goes.
private final class ObserverTokens {
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    func add(_ center: NotificationCenter, _ token: NSObjectProtocol) {
        tokens.append((center, token))
    }

    deinit {
        for (center, token) in tokens { center.removeObserver(token) }
    }
}
