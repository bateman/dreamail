import CryptoKit
import Foundation
import os

/// Persistent, greppable record of failures that a banner would otherwise
/// swallow, written to `~/Library/Logs/MishMail/diagnostics.log` inside the
/// app container and to the unified log under `dev.ronboger.MishMail.diag`.
///
/// Redacted by construction, because both sinks are readable by anything
/// that can read the user's logs (sysdiagnose, Console, a pasted bug report):
/// - accounts appear only as a salted hash tag (`acct-1a2b3c4d`), stable per
///   install so lines for one account can be correlated, never the address;
/// - endpoints are parameterized (`/messages/{id}`), the query is dropped;
/// - HTTP error bodies are never written: only the status, Google's
///   machine-readable reason/status tokens, a Retry-After value and the body
///   length. Bodies can echo search queries, label names or addresses;
/// - other errors are recorded by type, domain and code, never by their
///   localized description (which can carry an address).
/// There is no verbose mode, so tokens and message content cannot reach
/// either sink through this type.
///
/// The directory is 0700, the files 0600. Retention is bounded by size
/// (`maxBytes` per file, one rotated file) and by age (`maxAge`): the live
/// file is rotated once it is older than `maxAge`, and the rotated file is
/// deleted once its last write is older than `maxAge`, so no line outlives
/// about twice `maxAge`. Files written before this format (no `header`) held
/// raw bodies and addresses and are deleted on the first write.
enum DiagnosticLog {
    static let subsystem = "dev.ronboger.MishMail.diag"
    /// Rotate to `diagnostics.log.1` past this size so the file stays small.
    static let maxBytes = 512 * 1024
    /// Rotate the live file, and drop the rotated one, past this age.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    static let directoryPermissions: Int = 0o700
    static let filePermissions: Int = 0o600
    /// First line of every file in the redacted format.
    static let headerPrefix = "# MishMail diagnostics v2 (redacted) created="
    /// At most this many reason tokens per line.
    static let maxReasons = 4

    private static let logger = Logger(subsystem: subsystem, category: "errors")
    private static let queue = DispatchQueue(label: "dev.ronboger.MishMail.diagnostics")

    static var fileURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Logs/MishMail/diagnostics.log")
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

    /// One Gmail (or Google userinfo) HTTP failure.
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
            + "\(safeMethod(method)) \(parameterize(path)) status=\(code)"
        if let note { line += " \(note.text)" }
        line += " \(categorize(body: body))"
        return line
    }

    /// Error category only: `GmailError` by case and its non-identifying
    /// fields, anything else by type, NSError domain and code.
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
        let ns = error as NSError
        let typeName = token(String(describing: Swift.type(of: error))) ?? "unknown"
        let domain = token(ns.domain) ?? "unknown"
        return "error=\(typeName) domain=\(domain) code=\(ns.code)"
    }

    /// Google's machine-readable tokens from an error body, never its text:
    /// `error.status`, `error.errors[].reason`, `error.details[].reason`, or
    /// the OAuth `error` string; plus `Retry-After` and the body length.
    static func categorize(body: String) -> String {
        var parts: [String] = []
        var reasons: [String] = []
        var status: String?
        if let data = body.data(using: .utf8),
           let json = (try? JSONSerialization.jsonObject(with: firstJSONObject(data))) as? [String: Any] {
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

    /// The batch path appends `\nRetry-After: N` after the JSON; parse only
    /// the JSON object so that suffix doesn't make the whole body invalid.
    private static func firstJSONObject(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8),
              let range = text.range(of: "\nRetry-After:") else { return data }
        return Data(text[..<range.lowerBound].utf8)
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
        "modify", "trash", "untrash", "send", "attachments", "import", "insert",
        "batchModify", "batchDelete", "watch", "stop", "oauth2", "v2", "userinfo",
    ]

    static func parameterize(_ path: String) -> String {
        let bare = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        let noFragment = bare.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        let segments = noFragment.split(separator: "/", omittingEmptySubsequences: true)
            .map { staticSegments.contains(String($0)) ? String($0) : "{id}" }
        return "/" + segments.joined(separator: "/")
    }

    private static func safeMethod(_ method: String) -> String {
        let upper = method.uppercased()
        return ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(upper) ? upper : "OTHER"
    }

    /// A short identifier-like token, or nil: no spaces, quotes or `@`, so a
    /// free-text field cannot pass through.
    static func token(_ s: String) -> String? {
        guard (1...64).contains(s.count),
              s.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII
                  || "_.-".unicodeScalars.contains($0) }) else { return nil }
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

    static func header(created: Date) -> String {
        headerPrefix + ISO8601DateFormatter().string(from: created)
    }

    /// The creation date in the file's header line, or nil when the file has
    /// no header (a file from before the redacted format).
    static func headerDate(of url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256),
              let text = String(data: data, encoding: .utf8),
              let first = text.split(separator: "\n", maxSplits: 1).first,
              first.hasPrefix(headerPrefix) else { return nil }
        return ISO8601DateFormatter().date(from: String(first.dropFirst(headerPrefix.count)))
    }

    static func append(_ message: String, to url: URL, now: Date) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let old = url.appendingPathExtension("1")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: directoryPermissions])
            try fm.setAttributes([.posixPermissions: directoryPermissions], ofItemAtPath: dir.path)

            if fm.fileExists(atPath: url.path) {
                if let created = headerDate(of: url) {
                    let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
                    if size > maxBytes || now.timeIntervalSince(created) > maxAge {
                        try? fm.removeItem(at: old)
                        try? fm.moveItem(at: url, to: old)
                        try? fm.setAttributes([.posixPermissions: filePermissions],
                                              ofItemAtPath: old.path)
                    }
                } else {
                    // Legacy, unredacted format: drop it and its rotation.
                    try? fm.removeItem(at: url)
                    try? fm.removeItem(at: old)
                }
            }
            if let modified = (try? fm.attributesOfItem(atPath: old.path))?[.modificationDate] as? Date,
               now.timeIntervalSince(modified) > maxAge {
                try? fm.removeItem(at: old)
            }

            if !fm.fileExists(atPath: url.path) {
                let head = Data((header(created: now) + "\n").utf8)
                guard fm.createFile(atPath: url.path, contents: head,
                                    attributes: [.posixPermissions: filePermissions]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            try fm.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: url.path)

            let flat = message.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            let line = "\(ISO8601DateFormatter().string(from: now)) \(flat)\n"
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            logger.error("diagnostic log write failed: \(String(describing: type(of: error)), privacy: .public) \((error as NSError).code, privacy: .public)")
        }
    }
}
