import Foundation

/// Size of a label chip, after Gmail's conversation list: a rounded
/// rectangle (not a capsule) about 17.5 pt tall for 13 pt text, with a
/// 4 pt corner radius, 5.5 pt side padding and 6 pt between chips.
/// Everything is proportional to the chip's font size, so a chip drawn at
/// the list's font scale keeps the same shape.
struct LabelChipMetrics {
    /// Text size in points (already multiplied by any font scale).
    let fontSize: Double

    /// The reference text size the ratios below are taken at.
    static let referenceFontSize = 13.0

    private var ratio: Double { fontSize / Self.referenceFontSize }

    var cornerRadius: Double { 4 * ratio }
    var horizontalPadding: Double { 5.5 * ratio }
    /// Minimum chip height; the text is centered in it.
    var height: Double { 17.5 * ratio }
    /// Gap between two chips side by side.
    var spacing: Double { 6 * ratio }
}

/// Label chips in a thread-list row, at font scale 1 (multiply by it).
enum ThreadRowChipLayout {
    /// Gmail's 13 pt chip text.
    static let fontSize = 13.0
    /// Height of the row's trailing strip (chips, icons, date); the chip
    /// must fit in it.
    static let trailingStripHeight = 18.0
    /// Widest a chip gets; a longer name is truncated, so two chips never
    /// take more than about 250 pt from the subject.
    static let maxWidth = 120.0
}
