import Foundation

/// What the reading pane's web view did with one message's `<img>`
/// elements once its load ended (`HTMLBodyLayout.imageCensusJS`), for the
/// diagnostics log when an image failed. Counts and URL kinds only: no
/// URL, host, sender, subject or alt text.
struct RemoteImageCensus: Equatable, Sendable {
    /// The document's CSP let remote images load.
    var allowed = false
    var loaded = 0
    /// Ended without an image although remote images were allowed.
    var failed = 0
    /// Not loaded on purpose (remote images off for this message).
    var blocked = 0
    /// Still loading when the load counted as ended (`loadBound`).
    var pending = 0
    /// Failed images shown as their alt text.
    var altShown = 0
    /// Failed, by the kind of URL: `https:` (the host, its answer, or the
    /// network), `http:` (refused by the CSP), `data:`/`cid:`, and anything
    /// else (relative, empty, another scheme: nothing to load).
    var remote = 0
    var insecure = 0
    var inline = 0
    var unresolvable = 0
    /// Image loads the CSP refused (`img-src`), CSS images included.
    var csp = 0

    /// Parses the census script's JSON; nil for anything else.
    init?(scriptResult: Any?) {
        guard let text = scriptResult as? String, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        func count(_ key: String) -> Int {
            max(0, min((object[key] as? NSNumber)?.intValue ?? 0, 100_000))
        }
        allowed = (object["allowed"] as? Bool) ?? false
        loaded = count("loaded")
        failed = count("failed")
        blocked = count("blocked")
        pending = count("pending")
        altShown = count("altShown")
        remote = count("remote")
        insecure = count("insecure")
        inline = count("inline")
        unresolvable = count("unresolvable")
        csp = count("csp")
    }

    init() {}

    /// Worth a diagnostics line: an image failed, or (images allowed) the
    /// CSP refused one. With images blocked, refusals are the point.
    var hasFailures: Bool { failed > 0 || (allowed && csp > 0) }

    /// Fixed keys and integers only.
    var text: String {
        "allowed=\(allowed ? 1 : 0) loaded=\(loaded) failed=\(failed) blocked=\(blocked) pending=\(pending)"
            + " alt=\(altShown) csp=\(csp)"
            + " fail-https=\(remote) fail-http=\(insecure) fail-inline=\(inline)"
            + " fail-unresolvable=\(unresolvable)"
    }
}
