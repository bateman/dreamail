import Foundation
import CryptoKit
import Network
import AppKit

/// OAuth 2.0 Authorization Code + PKCE against Google, using the
/// "Desktop app" client type and a loopback redirect (RFC 8252).
/// The user's default browser handles sign-in; we catch the redirect
/// on 127.0.0.1 with a one-shot listener. No secrets leave the machine.
struct OAuthConfig {
    static let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        // Read-only view of Gmail filters in Settings. Accounts added before
        // this scope existed keep working; the filters pane just asks for a
        // re-sign-in to show them.
        "https://www.googleapis.com/auth/gmail.settings.basic",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
    ]
    static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    /// Client ID/secret for the user's own Google Cloud "Desktop app" OAuth
    /// client. For installed apps Google issues a "secret" that is explicitly
    /// not confidential; PKCE provides the actual protection.
    static var clientID: String {
        get { UserDefaults.standard.string(forKey: "oauth.clientID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "oauth.clientID") }
    }

    /// Fixture processes contain no real credentials and must remain entirely
    /// Keychain-free even if someone opens Settings or exits the demo inbox.
    static func usesKeychain(environment: [String: String]) -> Bool {
        environment["MISHMAIL_DEMO"] != "1"
            && environment["MISHMAIL_UI_TEST"] != "1"
    }

    static var clientSecret: String {
        get {
            guard usesKeychain(environment: ProcessInfo.processInfo.environment) else {
                return ""
            }
            do {
                return try resolveClientSecret(
                    from: Keychain.read("oauth.clientSecret"))
            } catch {
                NSLog("MishMail: client secret unreadable: %@", DiagnosticLog.describe(error))
                return ""
            }
        }
        set {
            guard usesKeychain(environment: ProcessInfo.processInfo.environment) else {
                return
            }
            try? Keychain.set(newValue, forKey: "oauth.clientSecret")
        }
    }
    static var isConfigured: Bool { !clientID.isEmpty }

    /// Token requests must distinguish an absent optional desktop-client
    /// secret from a temporarily inaccessible saved secret.
    static func clientSecretForRequest() throws -> String {
        guard usesKeychain(environment: ProcessInfo.processInfo.environment) else {
            return ""
        }
        return try resolveClientSecret(from: Keychain.read("oauth.clientSecret"))
    }

    /// Pure result mapping for hostless tests.
    static func resolveClientSecret(from result: KeychainReadResult) throws -> String {
        switch result {
        case .value(let value): return value
        case .notFound: return ""
        case .unavailable(let status): throw KeychainError.status(status)
        }
    }

    /// Parses Google's downloaded `client_secret_*.json` (Desktop-app clients
    /// use the `installed` key; `web` is tolerated too). Returns nil for
    /// anything that isn't a recognizable Google client credentials file.
    static func parseCredentialsJSON(_ data: Data) -> (clientID: String, clientSecret: String)? {
        struct Wrapper: Decodable {
            struct Client: Decodable {
                let client_id: String
                let client_secret: String?
            }
            let installed: Client?
            let web: Client?
        }
        guard let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data),
              let client = wrapper.installed ?? wrapper.web,
              !client.client_id.isEmpty else { return nil }
        return (client.client_id, client.client_secret ?? "")
    }
}

struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Int
    let refresh_token: String?
}

enum OAuthError: LocalizedError {
    case notConfigured
    case badRedirect
    case authorizationDenied(String)
    case tokenExchangeFailed(String)
    case invalidGrant
    case cancelled
    case timedOut
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set your Google OAuth Client ID in Settings first."
        case .badRedirect: return "The sign-in redirect was malformed."
        case .authorizationDenied(let reason): return "Google declined the sign-in: \(reason)."
        case .tokenExchangeFailed(let body): return "Token exchange failed: \(body)"
        case .invalidGrant:
            return "Google no longer accepts this account's saved sign-in (expired or revoked). Reauthorize the account in Settings → Accounts."
        case .cancelled: return "Sign-in was cancelled."
        case .timedOut: return "Sign-in timed out. Try again from MishMail."
        case .randomGenerationFailed(let status):
            return "Secure random generation failed (OSStatus \(status)). Sign-in was cancelled."
        }
    }
}

final class OAuthService {
    /// How long the loopback catcher waits for the browser redirect before
    /// giving up and tearing the listener down. Overridable in tests.
    static var loopbackTimeout: Duration = .seconds(5 * 60)

    /// Runs the full interactive flow and returns (refreshToken, accessToken).
    /// When `loginHint` is set (reauthorizing an existing account), Google
    /// preselects that account instead of showing the account chooser.
    func signIn(loginHint: String? = nil) async throws -> (refreshToken: String, accessToken: String) {
        guard OAuthConfig.isConfigured else { throw OAuthError.notConfigured }

        let verifier = try Self.randomURLSafe(64)
        let challenge = Self.s256(verifier)
        let state = try Self.randomURLSafe(32)

        let (port, codeTask) = try startLoopbackListener(expectedState: state)
        // Fixed path so the catcher can ignore unrelated local probes.
        let redirectURI = "http://127.0.0.1:\(port)/oauth2/callback"

        var comps = URLComponents(string: OAuthConfig.authEndpoint)!
        comps.queryItems = [
            .init(name: "client_id", value: OAuthConfig.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: OAuthConfig.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent select_account"),
        ]
        if let loginHint {
            comps.queryItems?.append(.init(name: "login_hint", value: loginHint))
        }
        let authURL = comps.url!
        _ = await MainActor.run { NSWorkspace.shared.open(authURL) }

        let code = try await withTaskCancellationHandler {
            try await codeTask.value
        } onCancel: {
            codeTask.cancel()
        }
        try Task.checkCancellation()
        let token = try await exchange(code: code, verifier: verifier, redirectURI: redirectURI)
        guard let refresh = token.refresh_token else {
            throw OAuthError.tokenExchangeFailed("no refresh_token returned")
        }
        return (refresh, token.access_token)
    }

    /// Refreshes an access token from a stored refresh token.
    static func refreshAccessToken(refreshToken: String) async throws -> (token: String, expiresIn: Int) {
        let clientSecret = try OAuthConfig.clientSecretForRequest()
        let body = [
            "client_id": OAuthConfig.clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        let resp: TokenResponse = try await postForm(OAuthConfig.tokenEndpoint, body)
        return (resp.access_token, resp.expires_in)
    }

    private func exchange(code: String, verifier: String, redirectURI: String) async throws -> TokenResponse {
        let clientSecret = try OAuthConfig.clientSecretForRequest()
        let body = [
            "client_id": OAuthConfig.clientID,
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        return try await Self.postForm(OAuthConfig.tokenEndpoint, body)
    }

    private static func postForm<T: Decodable>(_ urlString: String, _ form: [String: String]) async throws -> T {
        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (resp as? HTTPURLResponse)?.statusCode
            if status == 400, oauthErrorCode(from: data) == "invalid_grant" {
                throw OAuthError.invalidGrant
            }
            throw OAuthError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "unknown")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Parses the token endpoint's error body JSON and returns its `error`
    /// field (e.g. `"invalid_grant"`), or nil for non-JSON / missing field.
    static func oauthErrorCode(from data: Data) -> String? {
        struct ErrorBody: Decodable { let error: String? }
        return (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
    }

    // MARK: - Loopback listener

    /// Starts a one-shot HTTP listener on an ephemeral 127.0.0.1 port and
    /// returns the port plus a task that resolves to the auth code (or times
    /// out / cancels, tearing the listener down either way).
    ///
    /// Internal so unit tests can exercise the catcher without Google.
    ///
    /// `preferredPort` binds one exact port instead of an ephemeral one. Some
    /// vendors (the Codex CLI client) register a single fixed redirect URI and
    /// reject every other port. Binding fails if that port is already in use.
    /// `expectedPath`, when set, requires that exact callback path (OpenRouter
    /// uses `/callback/<uuid>` instead of OAuth `state`). An empty
    /// `expectedState` skips the state check for vendors that do not send one
    /// and must be paired with a unique `expectedPath`.
    ///
    /// `limits` bounds what local clients can hold open while the listener
    /// waits (see `LoopbackLimits`); `onEvent` reports admissions, refusals,
    /// deadlines and teardown so tests can synchronize on them.
    func startLoopbackListener(expectedState: String,
                               preferredPort: UInt16? = nil,
                               expectedPath: String? = nil,
                               limits: LoopbackLimits = .standard,
                               onEvent: ((LoopbackListenerEvent) -> Void)? = nil)
        throws -> (UInt16, Task<String, Error>) {
        precondition(
            !expectedState.isEmpty || !(expectedPath ?? "").isEmpty,
            "empty expectedState requires a unique expectedPath")
        // Bind to 127.0.0.1 only (RFC 8252 §8.3): the redirect catcher must
        // not be reachable from other machines on the network.
        let params = NWParameters.tcp
        let wanted = preferredPort.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: wanted)
        let listener = try NWListener(using: params)
        // One serial queue for the listener, its connections and their
        // deadlines, so their handlers never interleave.
        let queue = DispatchQueue(label: "MishMail.OAuthLoopback")
        let connections = LoopbackConnectionTracker(
            limits: limits, queue: queue, onEvent: onEvent)
        // Serialize finish/yield so a second concurrent connection can't race
        // the stream after the first legitimate callback already completed.
        let lock = NSLock()
        var finished = false
        let stream = AsyncThrowingStream<String, Error> { continuation in
            func complete(_ result: Result<String, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                switch result {
                case .success(let code):
                    continuation.yield(code)
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
            listener.newConnectionHandler = { conn in
                // At the cap the oldest connection still waiting for its
                // request line makes room, so idle sockets can't lock the
                // browser's redirect out. After teardown, or when every open
                // connection is already being answered, the newcomer is closed
                // unread.
                guard connections.admit(conn) else {
                    conn.cancel()
                    return
                }
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .failed: conn.cancel()
                    case .cancelled: connections.release(conn)
                    default: break
                    }
                }
                conn.start(queue: queue)
                Self.receiveRequestLine(on: conn, into: Data()) { data in
                    // A complete request line is no longer evictable: it may
                    // be the redirect, and its reply takes milliseconds.
                    if data != nil { connections.requestLineReceived(on: conn) }
                    // Browsers open speculative connections and request
                    // /favicon.ico; ignore anything that isn't the actual
                    // OAuth redirect instead of tearing the listener down.
                    // Wrong-state probes are also ignored (not fatal) so a
                    // local process can't abort a legitimate sign-in by
                    // racing a forged request.
                    guard let data, let request = String(data: data, encoding: .utf8),
                          let firstLine = request.split(separator: "\r\n").first,
                          let pathPart = firstLine.split(separator: " ").dropFirst().first,
                          let comps = URLComponents(string: String(pathPart)),
                          Self.callbackPathMatches(comps.path, expectedPath: expectedPath),
                          let items = comps.queryItems,
                          items.contains(where: { $0.name == "code" || $0.name == "error" }) else {
                        conn.cancel()
                        return
                    }
                    let code = items.first { $0.name == "code" }?.value
                    let state = items.first { $0.name == "state" }?.value
                    let errorParam = items.first { $0.name == "error" }?.value
                    let stateOK = expectedState.isEmpty || state == expectedState
                    // Reply with a page either way so the browser (or a probe)
                    // gets a clean HTTP close. Only a matching state can finish
                    // the stream — forged error=access_denied must not abort
                    // a legitimate in-flight sign-in.
                    let ok = stateOK && code != nil
                    let html = ok
                        ? "<html><body style='font-family:-apple-system'><h2>Signed in.</h2>You can close this tab and return to MishMail.</body></html>"
                        : "<html><body style='font-family:-apple-system'><h2>Sign-in failed.</h2>You can close this tab and try again from MishMail.</body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                    conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        conn.cancel()
                        guard stateOK else { return } // keep listening
                        if ok, let code {
                            complete(.success(code))
                        } else if let errorParam {
                            // Surface Google's actual reason (e.g. access_denied)
                            // rather than a generic malformed-redirect message.
                            complete(.failure(OAuthError.authorizationDenied(errorParam)))
                        } else {
                            complete(.failure(OAuthError.badRedirect))
                        }
                    })
                }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let err) = state { complete(.failure(err)) }
            }
            // Success, failure, timeout and caller cancellation all end the
            // stream: stop accepting and close every connection still open.
            continuation.onTermination = { _ in
                listener.cancel()
                connections.closeAll()
            }
        }
        listener.start(queue: queue)
        // Wait briefly for the port to be assigned.
        var port: UInt16 = 0
        for _ in 0..<100 {
            if let p = listener.port?.rawValue, p != 0 { port = p; break }
            usleep(10_000)
        }
        guard port != 0 else {
            listener.cancel()
            connections.closeAll()
            throw OAuthError.badRedirect
        }
        let timeout = Self.loopbackTimeout
        let task = Task<String, Error> {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    for try await code in stream { return code }
                    throw OAuthError.cancelled
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw OAuthError.timedOut
                }
                // First finisher wins; cancel the other (stream termination
                // cancels the NWListener and its connections via onTermination).
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        }
        return (port, task)
    }

    /// True for every registered redirect path this app uses — Google's
    /// `/oauth2/callback`, the LLM vendors' `/callback` and `/auth/callback` —
    /// plus the bare `/` Google sometimes normalizes empty paths to.
    static func isOAuthCallbackPath(_ path: String) -> Bool {
        path == "/oauth2/callback" || path == "/oauth2callback" || path == "/callback"
            || path == "/auth/callback" || path == "/" || path.isEmpty
    }

    /// Exact `expectedPath` when the vendor uses a unique callback (OpenRouter).
    /// Otherwise the known Gmail / LLM redirect paths.
    static func callbackPathMatches(_ path: String, expectedPath: String?) -> Bool {
        if let expectedPath { return path == expectedPath }
        return isOAuthCallbackPath(path)
    }

    /// Reads a connection until the HTTP request line's CRLF arrives, then
    /// hands the accumulated bytes (which may include following headers) to
    /// `completion`. Yields `nil` for connections that close, error, or pass
    /// 16 KB without completing a line — the caller cancels those as probes
    /// and keeps listening. (A bare-LF request line never completes — fine:
    /// browsers always send CRLF, and the old code tolerated LF only for
    /// raw-`nc` testing.)
    ///
    /// A single `receive` can fire on a fragment of the request (its minimum
    /// is one byte), and the parser only ever needs the first line; without
    /// this loop a redirect delivered in more than one segment was mistaken
    /// for a probe and the legitimate sign-in was dropped.
    private static func receiveRequestLine(
        on conn: NWConnection,
        into buffer: Data,
        completion: @escaping (Data?) -> Void
    ) {
        let crlf = Data([0x0D, 0x0A])
        let maxBytes = 16 * 1024
        conn.receive(minimumIncompleteLength: 1, maximumLength: maxBytes) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: crlf) != nil {
                completion(buffer)
            } else if error == nil, !isComplete, buffer.count < maxBytes {
                receiveRequestLine(on: conn, into: buffer, completion: completion)
            } else {
                completion(nil)
            }
        }
    }

    // MARK: - PKCE helpers

    static func randomURLSafe(
        _ count: Int,
        fill: (UnsafeMutableRawPointer, Int) -> OSStatus = { buffer, length in
            SecRandomCopyBytes(kSecRandomDefault, length, buffer)
        }
    ) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecParam }
            return fill(base, count)
        }
        guard status == errSecSuccess else {
            throw OAuthError.randomGenerationFailed(status)
        }
        return Data(bytes).base64URLEncoded()
    }

    private static func s256(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncoded()
    }
}

/// Bounds on the loopback redirect catcher (RFC 8252 §8.3 listener). Any
/// local process can connect to 127.0.0.1 while the user signs in; these
/// limits stop it from holding connections open or flooding the listener.
struct LoopbackLimits: Equatable {
    /// Connections open at once. Browsers open a few speculative ones next
    /// to the redirect itself. A connection beyond this evicts the oldest one
    /// that hasn't sent its request line yet.
    var maxConnections: Int
    /// How long one connection may stay open, from acceptance through the
    /// request line (16 KiB at most) to the reply. A real redirect needs
    /// milliseconds; a slow or idle client is closed when this runs out.
    var connectionDeadline: Duration

    static let standard = LoopbackLimits(maxConnections: 16, connectionDeadline: .seconds(10))
}

/// What the loopback listener did with local connections.
enum LoopbackListenerEvent: Equatable {
    /// A connection was admitted; `open` counts it.
    case accepted(open: Int)
    /// The cap was reached: the oldest connection still waiting for its
    /// request line is being closed to admit a newer one.
    case evicted
    /// A connection was closed unread: the listener is closing, or every
    /// open connection at the cap is already being answered.
    case refused
    /// An admitted connection ran out of time and is being closed.
    case deadlineExpired
    /// An admitted connection closed; `open` no longer counts it.
    case released(open: Int)
    /// The sign-in ended: every open connection was cancelled and no new
    /// one will be admitted.
    case closedAll
}

/// Tracks the loopback listener's open connections: enforces the cap, arms
/// a deadline per connection and cancels them all when the sign-in ends.
///
/// Thread-safe. `closeAll()` does its work on the listener's serial queue,
/// so it can't run between a connection's admission and its `start`.
/// Events are reported outside the lock (the hook is a test seam; it is nil
/// in production).
final class LoopbackConnectionTracker {
    private struct Entry {
        let connection: NWConnection
        let deadline: DispatchWorkItem
        /// Admission order, so eviction picks the oldest.
        let order: UInt64
        var requestLineReceived = false
    }

    private let maxConnections: Int
    private let deadline: DispatchTimeInterval
    private let queue: DispatchQueue
    private let onEvent: ((LoopbackListenerEvent) -> Void)?
    private let lock = NSLock()
    // Entries hold their connection strongly, so an ObjectIdentifier key
    // can't be reused by another connection while it is tracked.
    private var open: [ObjectIdentifier: Entry] = [:]
    private var nextOrder: UInt64 = 0
    private var closed = false

    init(limits: LoopbackLimits, queue: DispatchQueue,
         onEvent: ((LoopbackListenerEvent) -> Void)?) {
        precondition(limits.maxConnections > 0 && limits.connectionDeadline > .zero,
                     "loopback limits must allow one connection for some time")
        let parts = limits.connectionDeadline.components
        let nanoseconds = parts.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        self.maxConnections = limits.maxConnections
        self.deadline = nanoseconds.overflow
            ? .never
            : .nanoseconds(Int(clamping: nanoseconds.partialValue + parts.attoseconds / 1_000_000_000))
        self.queue = queue
        self.onEvent = onEvent
    }

    /// Admits `connection` and arms its deadline, evicting the oldest
    /// connection still waiting for its request line when the cap is
    /// reached. Returns false, and the caller cancels `connection`, after
    /// `closeAll()` or when no open connection can be evicted.
    func admit(_ connection: NWConnection) -> Bool {
        let deadline = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.expire(connection)
        }
        lock.lock()
        var evicted: Entry?
        if !closed, open.count >= maxConnections,
           let oldest = open.values.filter({ !$0.requestLineReceived }).min(by: { $0.order < $1.order }) {
            // Untracked now; its `.cancelled` state finds nothing to release.
            evicted = open.removeValue(forKey: ObjectIdentifier(oldest.connection))
        }
        let admitted = !closed && open.count < maxConnections
        if admitted {
            open[ObjectIdentifier(connection)] = Entry(
                connection: connection, deadline: deadline, order: nextOrder)
            nextOrder += 1
        }
        let count = open.count
        lock.unlock()
        if let evicted {
            evicted.deadline.cancel()
            onEvent?(.evicted)
            evicted.connection.cancel()
        }
        guard admitted else {
            onEvent?(.refused)
            return false
        }
        queue.asyncAfter(deadline: .now() + self.deadline, execute: deadline)
        onEvent?(.accepted(open: count))
        return true
    }

    /// Marks a connection whose request line arrived; it can't be evicted.
    func requestLineReceived(on connection: NWConnection) {
        lock.lock()
        open[ObjectIdentifier(connection)]?.requestLineReceived = true
        lock.unlock()
    }

    /// Forgets a connection that reached `.cancelled`, however it got there.
    func release(_ connection: NWConnection) {
        lock.lock()
        let entry = open.removeValue(forKey: ObjectIdentifier(connection))
        let count = open.count
        lock.unlock()
        guard let entry else { return }
        entry.deadline.cancel()
        onEvent?(.released(open: count))
    }

    /// Cancels every open connection and refuses any later one. Idempotent.
    /// Runs on the listener's queue: called from stream termination on an
    /// arbitrary thread, it must not slip between `admit` and `start`.
    func closeAll() {
        queue.async { [self] in
            lock.lock()
            guard !closed else { lock.unlock(); return }
            closed = true
            let entries = Array(open.values)
            open.removeAll()
            lock.unlock()
            for entry in entries {
                entry.deadline.cancel()
                entry.connection.cancel()
            }
            onEvent?(.closedAll)
        }
    }

    private func expire(_ connection: NWConnection) {
        lock.lock()
        let tracked = open[ObjectIdentifier(connection)] != nil
        lock.unlock()
        guard tracked else { return }
        onEvent?(.deadlineExpired)
        // `.cancelled` then releases it through the state handler.
        connection.cancel()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
