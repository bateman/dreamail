import Foundation

/// Content-Security-Policy for sandboxed HTML email rendering.
/// Kept free of AppKit so unit tests can pin the policy string.
enum HTMLBodyCSP {
    /// Meta tag injected into the message pane document head.
    ///
    /// - `base-uri 'none'` blocks phishing via a crafted `<base href>`.
    /// - `form-action` / `frame-src` / `object-src` are explicit even though
    ///   `default-src 'none'` covers them (defense in depth across WebKit revisions).
    /// - Remote images, when opted in, are HTTPS-only — no cleartext tracking pixels.
    /// - With them opted in, `upgrade-insecure-requests` turns every `http:`
    ///   request the document makes (an image the scanner did not rewrite, a
    ///   redirect from https to http) into its `https:` form before the
    ///   `img-src` check, as Gmail shows such images through its https proxy.
    ///   Plain `http:` is never admitted; links are not navigations this
    ///   document performs (the app opens them), so they are unchanged.
    static func metaTag(allowRemoteImages: Bool) -> String {
        allowRemoteImages ? allowedMetaTag : blockedMetaTag
    }

    /// Whether `meta` is the app's allowed variant: the document assembled
    /// with it loads remote images, so its insecure image URLs are upgraded.
    static func allowsRemoteImages(_ meta: String) -> Bool {
        meta == allowedMetaTag
    }

    private static let blockedMetaTag = build(imgSrc: "data: cid:", upgrade: false)
    private static let allowedMetaTag = build(imgSrc: "data: cid: https:", upgrade: true)

    private static func build(imgSrc: String, upgrade: Bool) -> String {
        var directives = [
            "default-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
            "frame-src 'none'",
            "object-src 'none'",
            "img-src \(imgSrc)",
            "style-src 'unsafe-inline'",
        ]
        if upgrade { directives.append("upgrade-insecure-requests") }
        let policy = directives.joined(separator: "; ")
        return "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
    }
}
