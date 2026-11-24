import SwiftUI

extension Color {
    /// Opaque sRGB color from a label color component.
    init(_ rgb: LabelRGB) {
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}

extension LabelPillStyle.Appearance {
    init(_ scheme: ColorScheme) {
        self = scheme == .dark ? .dark : .light
    }
}

/// A label as a solid pill in its Gmail color, with readable text and an
/// outline when the fill would melt into the surface. All the color
/// decisions are `LabelPillStyle.resolve`.
struct LabelPill<Trailing: View>: View {
    let name: String
    let colors: LabelColors
    let surface: LabelPillStyle.Surface
    let font: Font
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let trailing: () -> Trailing
    @Environment(\.colorScheme) private var colorScheme

    init(name: String, colors: LabelColors,
         surface: LabelPillStyle.Surface = .content,
         font: Font = .system(size: 10.5, weight: .medium),
         horizontalPadding: CGFloat = 8, verticalPadding: CGFloat = 2.5,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.name = name
        self.colors = colors
        self.surface = surface
        self.font = font
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.trailing = trailing
    }

    var body: some View {
        let style = LabelPillStyle.resolve(colors, appearance: .init(colorScheme), surface: surface)
        HStack(spacing: 4) {
            Text(name)
                .font(font)
                .lineLimit(1)
            trailing()
        }
        .foregroundStyle(Color(style.text))
        .padding(.horizontal, horizontalPadding).padding(.vertical, verticalPadding)
        .background(Color(style.fill), in: Capsule())
        .overlay {
            if style.needsBorder {
                Capsule().strokeBorder(Color(style.border), lineWidth: 1)
            }
        }
    }
}

extension LabelPill where Trailing == EmptyView {
    init(name: String, colors: LabelColors,
         surface: LabelPillStyle.Surface = .content,
         font: Font = .system(size: 10.5, weight: .medium),
         horizontalPadding: CGFloat = 8, verticalPadding: CGFloat = 2.5) {
        self.init(name: name, colors: colors, surface: surface, font: font,
                  horizontalPadding: horizontalPadding, verticalPadding: verticalPadding,
                  trailing: { EmptyView() })
    }
}

/// A label's color as a dot (filter list, picker, organizer), with the same
/// fill and outline rule as the pill.
struct LabelDot: View {
    let colors: LabelColors
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    init(colors: LabelColors, size: CGFloat = 9) {
        self.colors = colors
        self.size = size
    }

    var body: some View {
        let style = LabelPillStyle.resolve(colors, appearance: .init(colorScheme))
        Circle()
            .fill(Color(style.fill))
            .frame(width: size, height: size)
            .overlay {
                if style.needsBorder {
                    Circle().strokeBorder(Color(style.border), lineWidth: 1)
                }
            }
    }
}
