import CoreGraphics

/// Height an expanded message card gives its HTML body before and after the
/// body measures itself.
///
/// The web view reports its content height only after WebKit lays the
/// document out, a few frames after the card mounts. Until then the card
/// uses the height this body settled at last time (re-open, or a neighbor
/// pre-rendered offscreen), so the first frame already has the body's
/// length; only a body never measured before starts at `placeholder`.
enum MessageBodyHeight {
    /// Height of a body that has never been measured: about five lines.
    /// The web view stays hidden until its first report, so this is blank
    /// space, never a clipped body.
    static let placeholder: CGFloat = 120

    /// The card's body height: the live measurement when there is one,
    /// otherwise the cached height, otherwise `placeholder`.
    static func display(measured: CGFloat?, cached: CGFloat?) -> CGFloat {
        if let measured, measured > 0 { return measured }
        if let cached, cached > 0 { return cached }
        return placeholder
    }
}
