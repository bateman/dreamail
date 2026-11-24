import Foundation

/// How remote images in HTML mail are allowed without a per-message click.
///
/// Default is `.always` (`defaultPolicy`, the only place it is defined):
/// HTTPS images load when the user opens a message. `autoLoads` is the one
/// decision the message card and the neighbour pre-render both use. `.vip` is the middle
/// ground — trusted senders get images automatically; everyone else needs
/// Load images. `.ask` blocks every message until the user clicks.
///
/// Whatever the policy, mail in Spam never auto-loads (as in Gmail), and
/// neighbour pre-render never loads remote images (`HTMLBodyPrerenderPolicy`).
enum RemoteImagePolicy: String, CaseIterable, Identifiable {
    case ask
    case vip
    case always

    var id: String { rawValue }

    static let defaultsKey = "remoteImagePolicy"
    /// Brief boolean toggle shipped before the three-way picker.
    static let legacyBoolKey = "loadRemoteImagesByDefault"

    /// The policy of an install that never chose one. Single definition:
    /// `stored`, `from(raw:)` and the `@AppStorage` fallbacks all read it.
    /// (An `@AppStorage` fallback only applies while the key is absent, so
    /// it agrees with `from(raw:)`.)
    static let defaultPolicy: RemoteImagePolicy = .always

    /// Parses a stored raw value. No value (never chose) follows the
    /// default; a value that is present but unknown (a newer build's choice,
    /// a corrupted plist) fails closed to `.ask`.
    static func from(raw: String?) -> RemoteImagePolicy {
        guard let raw else { return defaultPolicy }
        return RemoteImagePolicy(rawValue: raw) ?? .ask
    }

    var title: String {
        switch self {
        case .ask: return "Ask each time"
        case .vip: return "VIP senders"
        case .always: return "Always"
        }
    }

    /// Policy-specific explanation. Settings appends `alwaysBlockedNote`.
    var footer: String {
        switch self {
        case .ask:
            return "No remote image loads until you click Load images on a message, or load them for the whole conversation from its menu."
        case .vip:
            return "HTTPS images load automatically only from VIP senders that pass Gmail's authentication checks. Other messages need a click."
        case .always:
            return "HTTPS images load when a message is opened: clicking it, moving to it in the list with the reading pane showing, or landing on it after archive or delete. The sender's servers then learn when you opened it, your IP address (approximate location and network), and details of your Mac's mail client. MishMail downloads each image once and keeps it encrypted with the message, so opening it again sends nothing. Choose Ask each time to stop this."
        }
    }

    /// Note shown under every policy: what stays blocked regardless.
    static let alwaysBlockedNote =
        "Messages in Spam always need their own click, and conversations you have not opened never load remote images. Cleartext (http) image URLs stay blocked either way."

    /// Whether `labelIds` (space-separated Gmail label ids) put the message
    /// in Spam.
    static func isSpam(labelIds: String) -> Bool {
        SyncEngine.labelIdsContain(labelIds, "SPAM")
    }

    /// The whole decision for one message card: may it fetch remote images
    /// without a further click?
    ///
    /// Spam is the message's own `SPAM` label or the thread's `inSpam` flag.
    /// The thread row is written optimistically when the user marks spam;
    /// message rows keep their old labels until history sync, so the thread
    /// flag closes that window.
    static func autoLoads(
        policy: RemoteImagePolicy,
        fromHeader: String,
        messageLabelIds: String,
        senderAuthenticated: Bool?,
        threadInSpam: Bool,
        vipEmails: Set<String>,
        messageOptIn: Bool,
        threadOptIn: Bool
    ) -> Bool {
        allows(
            policy: policy,
            senderEmail: MessageParser.emailAddress(fromHeader),
            vipEmails: vipEmails,
            messageOptIn: messageOptIn,
            threadOptIn: threadOptIn,
            senderAuthenticated: senderAuthenticated,
            inSpam: threadInSpam || isSpam(labelIds: messageLabelIds))
    }

    /// `autoLoads` for a stored message row.
    static func autoLoads(
        message: Message,
        threadInSpam: Bool,
        policy: RemoteImagePolicy,
        vipEmails: Set<String>,
        messageOptIn: Bool = false,
        threadOptIn: Bool = false
    ) -> Bool {
        autoLoads(
            policy: policy,
            fromHeader: message.fromHeader,
            messageLabelIds: message.labelIds,
            senderAuthenticated: message.senderAuth,
            threadInSpam: threadInSpam,
            vipEmails: vipEmails,
            messageOptIn: messageOptIn,
            threadOptIn: threadOptIn)
    }

    /// Whether this message may fetch remote images without a further click.
    /// `messageOptIn` / `threadOptIn` are explicit UI loads for this session.
    ///
    /// Order matters:
    /// 1. The message's own Load images click always wins.
    /// 2. `inSpam` blocks everything else under every policy (Gmail does the
    ///    same): spam is where tracking pixels and address-validation beacons
    ///    live. "Load images for this conversation" does not reach a Spam
    ///    message; it needs its own click.
    /// 3. The conversation-wide opt-in.
    /// 4. The policy.
    ///
    /// `senderAuthenticated` is the verdict parsed from Gmail's own
    /// `Authentication-Results` header at ingest: the `From:` header itself
    /// is unauthenticated, so under `.vip` anything but an aligned DMARC pass
    /// blocks auto-load (a spoofed VIP address must not fire tracking pixels).
    /// `nil` (rows synced before the verdict was stored) also blocks: failing
    /// closed costs one explicit click per message.
    static func allows(
        policy: RemoteImagePolicy,
        senderEmail: String,
        vipEmails: Set<String>,
        messageOptIn: Bool,
        threadOptIn: Bool,
        senderAuthenticated: Bool? = nil,
        inSpam: Bool = false
    ) -> Bool {
        if messageOptIn { return true }
        if inSpam { return false }
        if threadOptIn { return true }
        switch policy {
        case .ask: return false
        case .always: return true
        case .vip:
            guard senderAuthenticated == true else { return false }
            let email = senderEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !email.isEmpty && vipEmails.contains(email)
        }
    }

    /// One-shot migration from the old boolean default onto the string key.
    ///
    /// Only writes when the legacy key was actually present — installs that
    /// never chose leave `remoteImagePolicy` unset so they follow
    /// `defaultPolicy` (this is how the move from `.ask` to `.always` reaches
    /// them). An explicit stored choice, `ask` included, is never touched.
    /// `MishMailApp.init` runs it before any window exists, so a legacy
    /// "don't load" user never renders a message under the `.always` default.
    static func migrateIfNeeded(_ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: defaultsKey) == nil else { return }
        guard defaults.object(forKey: legacyBoolKey) != nil else { return }
        if defaults.bool(forKey: legacyBoolKey) {
            defaults.set(RemoteImagePolicy.always.rawValue, forKey: defaultsKey)
        } else {
            defaults.set(RemoteImagePolicy.ask.rawValue, forKey: defaultsKey)
        }
        defaults.removeObject(forKey: legacyBoolKey)
    }

    static func stored(_ defaults: UserDefaults = .standard) -> RemoteImagePolicy {
        migrateIfNeeded(defaults)
        return from(raw: defaults.string(forKey: defaultsKey))
    }
}
