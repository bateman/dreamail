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

/// A label as a Gmail-style chip: a rounded rectangle in the label's Gmail
/// color with readable text, and no outline unless the fill would vanish
/// into the surface. Shape from `LabelChipMetrics`, colors from
/// `LabelPillStyle.resolve`.
struct LabelPill<Trailing: View>: View {
    let name: String
    let colors: LabelColors
    let surface: LabelPillStyle.Surface
    let font: Font
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let minHeight: CGFloat
    let cornerRadius: CGFloat
    let maxWidth: CGFloat?
    let trailing: () -> Trailing
    @Environment(\.colorScheme) private var colorScheme

    /// A chip with medium-weight text of `fontSize` points (already
    /// multiplied by the list's font scale), sized by `LabelChipMetrics`.
    /// A name too long for `maxWidth` is truncated with an ellipsis.
    init(name: String, colors: LabelColors,
         surface: LabelPillStyle.Surface = .content,
         fontSize: CGFloat, maxWidth: CGFloat? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        let metrics = LabelChipMetrics(fontSize: Double(fontSize))
        self.init(name: name, colors: colors, surface: surface,
                  font: .system(size: fontSize, weight: .medium),
                  horizontalPadding: metrics.horizontalPadding, verticalPadding: 0,
                  minHeight: metrics.height, cornerRadius: metrics.cornerRadius,
                  maxWidth: maxWidth, trailing: trailing)
    }

    /// Any font, padded vertically instead of sized by the metrics (the
    /// account switcher's pill).
    init(name: String, colors: LabelColors,
         surface: LabelPillStyle.Surface = .content,
         font: Font, verticalPadding: CGFloat = 2.5,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(name: name, colors: colors, surface: surface, font: font,
                  horizontalPadding: 6, verticalPadding: verticalPadding,
                  minHeight: 0, cornerRadius: 4, maxWidth: nil, trailing: trailing)
    }

    private init(name: String, colors: LabelColors, surface: LabelPillStyle.Surface,
                 font: Font, horizontalPadding: Double, verticalPadding: CGFloat,
                 minHeight: Double, cornerRadius: Double, maxWidth: CGFloat?,
                 trailing: @escaping () -> Trailing) {
        self.name = name
        self.colors = colors
        self.surface = surface
        self.font = font
        self.horizontalPadding = CGFloat(horizontalPadding)
        self.verticalPadding = verticalPadding
        self.minHeight = CGFloat(minHeight)
        self.cornerRadius = CGFloat(cornerRadius)
        self.maxWidth = maxWidth
        self.trailing = trailing
    }

    var body: some View {
        let style = LabelPillStyle.resolve(colors, appearance: .init(colorScheme), surface: surface)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        CappedWidth(maxWidth: maxWidth ?? .infinity) {
            HStack(spacing: 4) {
                Text(name)
                    .font(font)
                    .lineLimit(1)
                    .truncationMode(.tail)
                trailing()
            }
            .foregroundStyle(Color(style.text))
            .padding(.horizontal, horizontalPadding).padding(.vertical, verticalPadding)
            .frame(minHeight: minHeight)
            .background(Color(style.fill), in: shape)
            .overlay {
                if style.needsBorder {
                    shape.strokeBorder(Color(style.border), lineWidth: 1)
                }
            }
        }
    }
}

/// Proposes at most `maxWidth` to its one subview and takes the subview's
/// own size, so a short chip stays short (unlike `.frame(maxWidth:)`,
/// which grows to the cap) and a long one truncates at the cap.
private struct CappedWidth: Layout {
    let maxWidth: CGFloat

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? .infinity, maxWidth), height: proposal.height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        // No width proposed (ideal size): the cap is the proposal, unless
        // there is none.
        let inner = proposal.width == nil && maxWidth == .infinity ? proposal : capped(proposal)
        return child.sizeThatFits(inner)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

extension LabelPill where Trailing == EmptyView {
    init(name: String, colors: LabelColors,
         surface: LabelPillStyle.Surface = .content, fontSize: CGFloat) {
        self.init(name: name, colors: colors, surface: surface, fontSize: fontSize,
                  trailing: { EmptyView() })
    }

    init(name: String, colors: LabelColors,
         surface: LabelPillStyle.Surface = .content,
         font: Font, verticalPadding: CGFloat = 2.5) {
        self.init(name: name, colors: colors, surface: surface, font: font,
                  verticalPadding: verticalPadding, trailing: { EmptyView() })
    }
}

/// A label's color as a dot (filter list, picker, organizer): the chip's
/// fill, with the dots' higher outline threshold.
struct LabelDot: View {
    let colors: LabelColors
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    init(colors: LabelColors, size: CGFloat = 9) {
        self.colors = colors
        self.size = size
    }

    var body: some View {
        let style = LabelPillStyle.resolve(colors, appearance: .init(colorScheme), shape: .dot)
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
