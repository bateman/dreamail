import SwiftUI
import AppKit

/// One account's avatar: its Google profile photo when one is stored,
/// otherwise the colored disc with the first initial (also the placeholder
/// while the photo loads). Circular at every size.
struct AccountAvatarView: View {
    /// Shown as the initial and read by VoiceOver.
    let name: String
    /// Stable color key for the disc (the account id).
    let key: String
    let size: CGFloat
    var photo: NSImage?

    var body: some View {
        Group {
            if let photo {
                Image(nsImage: photo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.stable(for: key))
                    .frame(width: size, height: size)
                    .overlay {
                        Text(String(name.prefix(1)).uppercased())
                            .font(.system(size: size * 0.48, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo == nil ? "\(name) account" : "\(name) account photo")
        .accessibilityAddTraits(.isImage)
    }
}
