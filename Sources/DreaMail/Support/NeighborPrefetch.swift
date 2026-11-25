import Foundation

/// Pure helper for Phase 2 neighbor-thread prefetch.
enum NeighborPrefetch {
    /// Previous and next thread ids in `displayOrder` around `selected`.
    /// Either side may be nil at list ends or when selection is missing.
    static func neighbors(selected: String?, in order: [String]) -> (prev: String?, next: String?) {
        guard let selected, let idx = order.firstIndex(of: selected) else {
            return (nil, nil)
        }
        let prev = idx > 0 ? order[idx - 1] : nil
        let next = idx + 1 < order.count ? order[idx + 1] : nil
        return (prev, next)
    }

    /// Payloads to warm around `selected`, nearest first.
    ///
    /// The selected row itself leads when it is not the open conversation:
    /// a highlighted row (the auto-highlighted top row after launch, or a
    /// browse focus the reading pane has not opened yet) is the next thing
    /// ↩ or a click opens. Without it the first open after launch always
    /// missed and paid the repository round trip on a busy main actor.
    static func targets(selected: String?, openedId: String?,
                        in order: [String]) -> [String] {
        guard let selected else { return [] }
        let (prev, next) = neighbors(selected: selected, in: order)
        let own: String? = selected == openedId ? nil : selected
        return [own, prev, next].compactMap { $0 }
    }

    /// Selection intents that warm payloads without opening the detail
    /// (opening intents warm through `openDetail`).
    static func warmsOnSelection(_ intent: ThreadSelectionIntent) -> Bool {
        intent == .browse || intent == .quiet
    }
}
