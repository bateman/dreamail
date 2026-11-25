import Foundation

/// Orders overlapping loads of the same thing: each load takes a ticket
/// when it starts, and only the newest ticket may publish its result. An
/// older load that finishes late (an off-main read) is dropped instead of
/// putting back what a newer one replaced.
struct LatestOnly {
    private(set) var current = 0

    mutating func begin() -> Int {
        current += 1
        return current
    }

    func isCurrent(_ ticket: Int) -> Bool {
        ticket == current
    }
}
