import CryptoKit
import Foundation
import GRDB
import os

/// Persistent, greppable record of failures that a banner would otherwise
/// swallow, written to `~/Library/Logs/DreaMail/diagnostics.log` inside the
/// app container and to the unified log under `io.github.bateman.DreaMail.diag`.
///
/// Redacted by construction, because both sinks are readable by anything
/// that can read the user's logs (sysdiagnose, Console, a pasted bug report):
/// - accounts appear only as a salted hash tag (`acct-1a2b3c4d`), stable per
///   install so lines for one account can be correlated, never the address;
/// - endpoints are parameterized (`/messages/{id}`), the query is dropped;
/// - HTTP error bodies are never written: only the status, Google's
///   machine-readable reason/status tokens, a Retry-After value and the body
///   length. Bodies can echo search queries, label names or addresses;
/// - other errors are recorded by type, domain and code (decoding errors by
///   case and coding path), never by their localized description, which can
///   carry an address.
/// There is no verbose mode, so tokens and message content cannot reach
/// either sink through this type.
///
/// The directory is 0700, the files 0600. Retention is bounded by size
/// (`maxBytes` per file, one rotated file) and by age (`maxAge`): the live
/// file is rotated once it is older than `maxAge`, and the rotated file is
/// deleted once its last write is older than `maxAge`. The same maintenance
/// runs at launch (`maintainAtLaunch`), not only when an error is logged, so
/// no line outlives about twice `maxAge` plus the time to the next launch.
/// Files written before this format (no `header`) held raw bodies and
/// addresses; the live and the rotated file are each deleted the first time
/// maintenance runs. The sink never follows a symlink at either path.
enum DiagnosticLog {
    static let subsystem = "io.github.bateman.DreaMail.diag"
    /// Rotate to `diagnostics.log.1` past this size so the file stays small.
    static let maxBytes = 512 * 1024
    /// Rotate the live file, and drop the rotated one, past this age.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    static let directoryPermissions: Int = 0o700
    static let filePermissions: Int = 0o600
    /// First line of every file in the redacted format.
    static let headerPrefix = "# DreaMail diagnostics v2 (redacted) created="
    /// At most this many reason tokens per line.
    static let maxReasons = 4
    static let maxTokenLength = 40

    private static let logger = Logger(subsystem: subsystem, category: "errors")
    private static let queue = DispatchQueue(label: "io.github.bateman.DreaMail.diagnostics")

    static var fileURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Logs/DreaMail/diagnostics.log")
    }

    /// Fixed context a call site may attach; deliberately not a free string,
    /// so no caller can route an identifier or a body into the line.
    enum Note: Equatable {
        /// One failing part of a batch response: `failing` of `total` ids.
        case batchPart(failing: Int, total: Int)
        /// A whole batch request for this many ids.
        case batchRequest(ids: Int)

        var text: String {
            switch self {
            case .batchPart(let failing, let total): return "batch-part=\(failing)/\(total)"
            case .batchRequest(let ids): return "batch-ids=\(ids)"
            }
        }
    }

    // MARK: - Entry points

    /// One Gmail (or Google userinfo) HTTP failure. `method` is a literal at
    /// every call site.
    static func gmailHTTP(account: String, method: String, path: String,
                          code: Int, body: String, note: Note? = nil) {
        record(format(account: account, method: method, path: path,
                      code: code, body: body, note: note))
    }

    /// A sync pass that ended in an error the user may see as a banner.
    static func syncFailure(account: String, error: Error) {
        record("SYNC-FAIL account=\(accountTag(account)) \(describe(error))")
    }

    // MARK: - Redaction

    static func format(account: String, method: String, path: String,
                       code: Int, body: String, note: Note? = nil,
                       salt: String = accountSalt) -> String {
        var line = "GMAIL-HTTP account=\(accountTag(account, salt: salt)) "
            + "\(method) \(parameterize(path)) status=\(code)"
        if let note { line += " \(note.text)" }
        line += " \(categorize(body: body))"
        return line
    }

    /// Error category only: `GmailError` by case and its non-identifying
    /// fields, `DecodingError` by case and coding path, `KeychainError` by
    /// OSStatus, GRDB's `DatabaseError` by SQLite result codes, anything else
    /// by type, NSError domain and code.
    static func describe(_ error: Error) -> String {
        if let g = error as? GmailError {
            switch g {
            case .http(let code, let body): return "http=\(code) \(categorize(body: body))"
            case .historyExpired: return "error=historyExpired"
            case .noRefreshToken: return "error=noRefreshToken"
            case .keychainUnavailable(_, let status): return "error=keychainUnavailable status=\(status)"
            case .partialFetch(let n): return "error=partialFetch failed=\(n)"
            }
        }
        if let d = error as? DecodingError { return describe(decoding: d) }
        if let keychain = error as? KeychainError, case .status(let status) = keychain {
            return "error=KeychainError status=\(status)"
        }
        if let db = error as? DatabaseError {
            // Never `description`: it carries the SQL text and the SQLite
            // message, which can quote values or a file path.
            return "error=DatabaseError code=\(db.resultCode.rawValue) "
                + "extended=\(db.extendedResultCode.rawValue)"
        }
        let ns = error as NSError
        let typeName = token(String(describing: Swift.type(of: error))) ?? "unknown"
        let domain = token(ns.domain) ?? "unknown"
        return "error=\(typeName) domain=\(domain) code=\(ns.code)"
    }

    /// The failing case and the coding path, so a change in Gmail's response
    /// shape stays diagnosable. Keys are schema, not user data; each still
    /// goes through `token`, and array indices are kept as numbers.
    static func describe(decoding error: DecodingError) -> String {
        let kind: String
        var context: DecodingError.Context?
        var missing: CodingKey?
        switch error {
        case .typeMismatch(_, let c): kind = "typeMismatch"; context = c
        case .valueNotFound(_, let c): kind = "valueNotFound"; context = c
        case .keyNotFound(let key, let c): kind = "keyNotFound"; context = c; missing = key
        case .dataCorrupted(let c): kind = "dataCorrupted"; context = c
        @unknown default: kind = "unknown"
        }
        let keys = (context?.codingPath ?? []) + (missing.map { [$0] } ?? [])
        let path = keys.suffix(8).map { key in
            key.intValue.map(String.init) ?? token(key.stringValue) ?? "?"
        }.joined(separator: ".")
        return "error=DecodingError case=\(kind) path=\(path.isEmpty ? "-" : path)"
    }

    /// Google's machine-readable tokens from an error body, never its text:
    /// `error.status`, `error.errors[].reason`, `error.details[].reason`, or
    /// the OAuth `error` string; plus `Retry-After` and the body length.
    static func categorize(body: String) -> String {
        var parts: [String] = []
        var reasons: [String] = []
        var status: String?
        if let json = (try? JSONSerialization.jsonObject(with: jsonPart(of: body))) as? [String: Any] {
            if let err = json["error"] as? [String: Any] {
                status = (err["status"] as? String).flatMap(token)
                for key in ["errors", "details"] {
                    for item in err[key] as? [[String: Any]] ?? [] {
                        if let r = (item["reason"] as? String).flatMap(token) { reasons.append(r) }
                    }
                }
            } else if let err = (json["error"] as? String).flatMap(token) {
                reasons.append(err)
            }
        }
        var seen = Set<String>()
        reasons = reasons.filter { seen.insert($0).inserted }.prefix(maxReasons).map { $0 }
        if !reasons.isEmpty { parts.append("reason=\(reasons.joined(separator: ","))") }
        if let status { parts.append("gstatus=\(status)") }
        if let retry = retryAfter(in: body) { parts.append("retry-after=\(retry)") }
        parts.append("body-bytes=\(body.utf8.count)")
        return parts.joined(separator: " ")
    }

    /// Call sites append `\nRetry-After: N` after the JSON; parse only the
    /// part before it so that suffix doesn't make the whole body invalid.
    private static func jsonPart(of body: String) -> Data {
        guard let range = body.range(of: "\nRetry-After:") else { return Data(body.utf8) }
        return Data(body[..<range.lowerBound].utf8)
    }

    private static func retryAfter(in body: String) -> Int? {
        guard let range = body.range(of: "Retry-After: ") else { return nil }
        let digits = body[range.upperBound...].prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 7 else { return nil }
        return Int(digits)
    }

    /// Path segments that are part of the Gmail / userinfo API shape. Any
    /// other segment is an identifier (message, thread, draft, label,
    /// attachment id) and is replaced by `{id}`.
    static let staticSegments: Set<String> = [
        "gmail", "v1", "users", "me", "messages", "threads", "drafts", "labels",
        "history", "batch", "profile", "settings", "filters", "sendAs",
        "modify", "trash", "untrash", "send", "attachments", "oauth2", "v2", "userinfo",
    ]

    static func parameterize(_ path: String) -> String {
        let bare = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        let segments = bare.split(separator: "/", omittingEmptySubsequences: true)
            .map { staticSegments.contains(String($0)) ? String($0) : "{id}" }
        return "/" + segments.joined(separator: "/")
    }

    /// A short identifier-like token, or nil: no spaces, quotes or `@`, so a
    /// free-text field cannot pass through; and no long or all-hex string,
    /// which is more likely an id than a reason or a type name.
    static func token(_ s: String) -> String? {
        guard (1...maxTokenLength).contains(s.count),
              s.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII
                  || "_.-".unicodeScalars.contains($0) }) else { return nil }
        if s.count >= 8, s.allSatisfy(\.isHexDigit) { return nil }
        return s
    }

    /// `acct-` plus 8 hex chars of SHA-256(salt + lowercased address). The
    /// per-install salt keeps the tag from being matched against a list of
    /// known addresses by someone who only has the log.
    static func accountTag(_ account: String, salt: String = accountSalt) -> String {
        let normalized = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data((salt + "\u{0}" + normalized).utf8))
        return "acct-" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static let saltKey = "DiagnosticLogAccountSalt"
    /// Random per-install salt, created on first use.
    static let accountSalt: String = {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: saltKey), !existing.isEmpty { return existing }
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        let salt = Data(bytes).base64EncodedString()
        defaults.set(salt, forKey: saltKey)
        return salt
    }()

    // MARK: - Sinks

    /// Private so every line goes through the redacting entry points above.
    private static func record(_ message: String) {
        logger.error("\(message, privacy: .public)")
        queue.async { append(message, to: fileURL, now: Date()) }
    }

    /// Purge, rotate and tighten the log at launch, so an install that stops
    /// failing still loses its legacy file and ages out old lines.
    static func maintainAtLaunch() {
        queue.async { maintain(url: fileURL, now: Date()) }
    }

    static func header(created: Date) -> String {
        headerPrefix + ISO8601DateFormatter().string(from: created)
    }

    /// The creation date in the file's header line, or nil when the file has
    /// no header (a file from before the redacted format) or is a symlink.
    static func headerDate(of url: URL) -> Date? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0,
              let first = String(bytes: buffer[..<n].prefix(while: { $0 != 0x0A }), encoding: .utf8),
              first.hasPrefix(headerPrefix) else { return nil }
        return ISO8601DateFormatter().date(from: String(first.dropFirst(headerPrefix.count)))
    }

    private enum Entry { case missing, regular(size: Int, modified: Date), directory, other }

    /// What sits at `path`, without following a symlink. A regular file with
    /// another hard link counts as `.other`: it is shared with a path outside
    /// the log, so only our name for it is removed.
    private static func entry(_ path: String) -> Entry {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .missing }
        switch st.st_mode & S_IFMT {
        case S_IFREG where st.st_nlink == 1:
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            return .regular(size: Int(st.st_size), modified: mtime)
        case S_IFDIR:
            return .directory
        default:
            return .other
        }
    }

    /// Set 0600 on a regular file without following a symlink.
    private static func tighten(_ path: String) {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        fchmod(fd, mode_t(filePermissions))
        close(fd)
    }

    /// Legacy purge, rotation by size and age, deletion of a stale rotated
    /// file, permission tightening. A symlink or other non-file at either
    /// path is unlinked (the link itself, never its target, and never
    /// recursively); a directory there is left alone, so a write fails closed.
    /// Returns false when the log directory is unusable.
    @discardableResult
    static func maintain(url: URL, now: Date) -> Bool {
        let dir = url.deletingLastPathComponent()
        let live = url.path
        let old = url.appendingPathExtension("1").path
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryPermissions])
        } catch {
            return false
        }
        // A symlinked log directory points somewhere else: don't touch it.
        guard case .directory = entry(dir.path) else { return false }
        chmod(dir.path, mode_t(directoryPermissions))

        switch entry(live) {
        case .regular(let size, _):
            if let created = headerDate(of: url) {
                if size > maxBytes || now.timeIntervalSince(created) > maxAge {
                    if case .directory = entry(old) { unlink(live) } else { rename(live, old) }
                }
            } else {
                unlink(live)
            }
        case .other:
            unlink(live)
        case .directory, .missing:
            break
        }

        switch entry(old) {
        case .regular(_, let modified):
            if headerDate(of: URL(fileURLWithPath: old)) == nil
                || now.timeIntervalSince(modified) > maxAge {
                unlink(old)
            } else {
                tighten(old)
            }
        case .other:
            unlink(old)
        case .directory, .missing:
            break
        }
        if case .regular = entry(live) { tighten(live) }
        return true
    }

    static func append(_ message: String, to url: URL, now: Date) {
        guard maintain(url: url, now: now) else {
            logger.error("diagnostic log directory unusable; not writing")
            return
        }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                      mode_t(filePermissions))
        guard fd >= 0 else {
            logger.error("diagnostic log open failed: errno \(errno, privacy: .public)")
            return
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else {
            logger.error("diagnostic log is not a private regular file; not writing")
            return
        }
        fchmod(fd, mode_t(filePermissions))
        var text = ""
        if st.st_size == 0 { text += header(created: now) + "\n" }
        text += "\(ISO8601DateFormatter().string(from: now)) \(message)\n"
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                logger.error("diagnostic log write failed: errno \(errno, privacy: .public)")
                return
            }
            offset += n
        }
    }
}
