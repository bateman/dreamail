import SwiftUI
import AppKit

/// One account's avatar: its Google profile photo when one is stored,
/// otherwise the colored disc with the first initial (also the placeholder
/// while the photo loads). Circular at every size.
///
/// With a `ring`, the account's label color is drawn as a ring around it,
/// with a gap of the background in between (`AccountRingStyle`,
/// `AccountRingMetrics`). The ring sits inside `size`, so the avatar's
/// footprint is the same with or without it.
struct AccountAvatarView: View {
    /// The ring around the avatar: the account's stored label color
    /// (`#rrggbb`, nil = default) and the surface it is drawn on.
    struct Ring {
        var storedHex: String?
        var surface: AccountRingStyle.Surface
    }

    /// Shown as the initial and read by VoiceOver.
    let name: String
    /// Stable color key for the disc and the default ring color (the
    /// account id).
    let key: String
    let size: CGFloat
    var photo: NSImage?
    var ring: Ring?
    /// Hidden from VoiceOver where the surrounding control already reads the
    /// account's name (the switcher rows and header).
    var decorative = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let metrics = AccountRingMetrics(size: Double(size))
        let inner = ring == nil ? size : CGFloat(metrics.photoDiameter)
        ZStack {
            if let ring {
                let style = AccountRingStyle.resolve(
                    storedHex: ring.storedHex, accountId: key,
                    appearance: colorScheme == .dark ? .dark : .light, surface: ring.surface)
                Circle()
                    .strokeBorder(ringColor(ring, style),
                                  lineWidth: CGFloat(AccountRingMetrics.ringWidth))
                if style.needsHairline {
                    Circle()
                        .strokeBorder(Self.color(style.hairline),
                                      lineWidth: CGFloat(AccountRingMetrics.hairlineWidth))
                }
            }
            disc(diameter: inner)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo == nil ? "\(name) account" : "\(name) account photo")
        .accessibilityAddTraits(.isImage)
        .accessibilityHidden(decorative)
    }

    /// A chosen color as stored; the default as the same system color the
    /// initial disc uses, so the two match in every appearance and macOS
    /// version.
    private func ringColor(_ ring: Ring, _ style: AccountRingStyle) -> Color {
        LabelRGB.normalizedHex(ring.storedHex) == nil
            ? Color.stable(for: key) : Self.color(style.color)
    }

    private static func color(_ rgb: LabelRGB) -> Color {
        Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    @ViewBuilder
    private func disc(diameter: CGFloat) -> some View {
        if let photo {
            Image(nsImage: photo)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.stable(for: key))
                .frame(width: diameter, height: diameter)
                .overlay {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: diameter * 0.48, weight: .semibold))
                        .foregroundStyle(.white)
                }
        }
    }
}
