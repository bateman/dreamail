import AppKit
import SwiftUI

/// The size of the label "⋮" (three stacked dots): no taller than the
/// sidebar glyph of the same row size, in whole points.
enum LabelMenuDots {
    static func layout(rowSize: SidebarRowSize) -> (diameter: CGFloat, gap: CGFloat, height: CGFloat) {
        let point = MailIconMetrics(rowSize: rowSize).pointSize
        let diameter = (point * 0.15).rounded()
        // Whole points, so no dot lands on a half pixel at 1x.
        let gap = (((point * 0.85).rounded() - 3 * diameter) / 2).rounded(.down)
        return (diameter, gap, 3 * diameter + 2 * gap)
    }

    static func size(rowSize: SidebarRowSize) -> NSSize {
        let l = layout(rowSize: rowSize)
        return NSSize(width: l.diameter, height: l.height)
    }
}
