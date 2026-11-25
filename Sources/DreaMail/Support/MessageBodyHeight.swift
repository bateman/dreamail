import CoreGraphics

/// Height an expanded message card gives its HTML body before and after the
/// body measures itself.
///
/// The web view reports its content height only after WebKit lays the
/// document out — the whole load for a large newsletter. Until then:
/// - a body measured before (re-open, or a neighbor pre-rendered offscreen)
///   uses that height, so the first frame already has the body's length;
/// - the open card of the reading pane reserves the rest of the pane, so it
///   fills the pane from the first frame and the content appears into it,
///   instead of opening as a short box that then jumps (the "reduced" pane);
/// - anything else starts at `placeholder`.
///
/// The reservation sizes the body's container only. The web view keeps its
/// own frame at `webViewHeight`, so what WebKit measures is unchanged, and
/// the first report replaces the reservation outright: the card grows to a
/// taller body or shrinks to a shorter one in one step, with no blank tail.
enum MessageBodyHeight {
    /// Height of a body that has never been measured: about five lines.
    /// The web view stays hidden until its first report, so this is blank
    /// space, never a clipped body.
    static let placeholder: CGFloat = 120

    /// Frame of the web view itself: the live measurement, else the cached
    /// height, else `placeholder`.
    static func webViewHeight(measured: CGFloat?, cached: CGFloat?) -> CGFloat {
        if let measured, measured > 0 { return measured }
        if let cached, cached > 0 { return cached }
        return placeholder
    }

    /// Height of the body's container: the web view's frame, raised to
    /// `reserve` only while the body has neither a measurement nor a cached
    /// height. `reserve` is nil for cards that do not fill the pane.
    static func containerHeight(measured: CGFloat?, cached: CGFloat?,
                                reserve: CGFloat?) -> CGFloat {
        let frame = webViewHeight(measured: measured, cached: cached)
        let known = (measured ?? 0) > 0 || (cached ?? 0) > 0
        guard !known, let reserve else { return frame }
        return max(frame, reserve)
    }

    /// Body height that makes the open card reach the bottom of the pane:
    /// the pane's visible height less the card's chrome above and around the
    /// body (header, spacing, padding). Never below `placeholder`; nil when
    /// the pane has not been laid out yet.
    static func paneReserve(viewportHeight: CGFloat,
                            chromeHeight: CGFloat) -> CGFloat? {
        guard viewportHeight > 0 else { return nil }
        return max(placeholder, viewportHeight - max(0, chromeHeight))
    }
}
