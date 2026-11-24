import Foundation

/// How remote images in HTML mail are allowed without a per-message click.
///
/// Default is `.always` (`defaultPolicy`, the only place it is defined):
/// HTTPS images load when the user opens a message. `.vip` is the middle
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
    static let defaultPolicy: RemoteImagePolicy = .always

    /// Parses a stored raw value; an unknown value falls back to the default.
    static func from(raw: String?) -> RemoteImagePolicy {
        raw.flatMap(RemoteImagePolicy.init(rawValue:)) ?? defaultPolicy
    }

    var title: String {
        switch self {
        case .ask: return "Ask each time"
        case .vip: return "VIP senders"
        case .always: return "Always"
        }
    }

    /// Policy-specific explanation. Settings appends the shared cleartext note.
    var footer: String {
        switch self {
        case .ask:
            return "No remote image loads until you click Load images on a message (or load all for the conversation). Senders can't see when you open their mail through images."
        case .vip:
            return "HTTPS images load automatically only from VIP senders that pass Gmail's authentication checks. Other messages need a click."
        case .always:
            return "HTTPS images load when you open a message. The sender's servers can then see when you opened it and your IP address, which reveals your approximate location."
        }
    }

    /// Note shown under every policy: what stays blocked regardless.
    static let alwaysBlockedNote =
        "Messages in Spam always need a click. Cleartext (http) image URLs stay blocked either way."

    /// Whether `labelIds` (space-separated Gmail label ids) put the message
    /// in Spam.
    static func isSpam(labelIds: String) -> Bool {
        labelIds.split(whereSeparator: \.isWhitespace).contains { $0 == "SPAM" }
    }

    /// Whether this message may fetch remote images without a further click.
    /// `messageOptIn` / `threadOptIn` are explicit UI loads for this session.
    ///
    /// `inSpam` blocks auto-load under every policy (Gmail does the same):
    /// spam is where tracking pixels and address-validation beacons live.
    /// The explicit opt-ins still win, so Load images works there.
    ///
    /// `senderAuthenticated` is the verdict parsed from Gmail's own
    /// `Authentication-Results` header at ingest: the `From:` header itself
    /// is unauthenticated, so under `.vip` anything but an aligned DMARC pass
    /// blocks auto-load (a spoofed VIP address must not fire tracking pixels).
    /// `nil` (rows synced before the verdict was stored — i.e. every existing
    /// mailbox) also blocks: failing closed costs one explicit click per
    /// message, and both per-message and per-thread opt-ins always win.
    static func allows(
        policy: RemoteImagePolicy,
        senderEmail: String,
        vipEmails: Set<String>,
        messageOptIn: Bool,
        threadOptIn: Bool,
        senderAuthenticated: Bool? = nil,
        inSpam: Bool = false
    ) -> Bool {
        if messageOptIn || threadOptIn { return true }
        if inSpam { return false }
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
