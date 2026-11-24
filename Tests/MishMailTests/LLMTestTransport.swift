import Foundation

/// Stands in for the network under `LLMClient`, `Ollama.send` and the
/// sign-in posts, and records every request that reaches it. A streaming
/// request cannot be answered (`URLSession.AsyncBytes` has no public
/// initialiser), so it is recorded and then fails like a dropped connection
/// the client does not retry.
final class LLMRecordingTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var dataBody = Data(#"{"data":[{"id":"model-a"}]}"#.utf8)

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
    }

    var transport: LLMTransport {
        LLMTransport(
            data: { [self] request in
                record(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                               httpVersion: nil, headerFields: nil)!
                return (dataBody, response)
            },
            bytes: { [self] request in
                record(request)
                throw URLError(.badServerResponse)
            })
    }
}

/// A Keychain stand-in: one saved value for every key, and a log of reads.
final class LLMRecordingSecrets: @unchecked Sendable {
    private let lock = NSLock()
    private var readKeys: [String] = []
    let value: String

    init(value: String = "sk-saved-not-real") { self.value = value }

    var reads: [String] {
        lock.lock(); defer { lock.unlock() }
        return readKeys
    }

    var reader: LLMClient.SecretReader {
        { [self] key in
            lock.lock(); readKeys.append(key); lock.unlock()
            return .value(value)
        }
    }
}
