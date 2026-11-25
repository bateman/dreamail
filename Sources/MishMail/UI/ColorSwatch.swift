import SwiftUI

/// One-click colour choice beside a colour well: the label palette's dot,
/// ringed when it is the colour in effect. Shared by the account label
/// colours and the accent colour setting.
struct ColorSwatch: View {
    let name: String
    let hex: String
    let selected: Bool
    let accessibilityID: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LabelDot(colors: LabelColors(background: hex, text: nil), size: 14)
                .padding(2)
                .overlay {
                    if selected {
                        Circle().strokeBorder(Color.primary, lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(accessibilityID)
    }
}
