import SwiftUI

// TEMPORARY probe (removed before review): which signals reach a
// `.listRowBackground` view on macOS, and whether the system selection
// highlight draws over it. Stripes, 12 pt each from the row's leading edge:
// 0 backgroundProminence == .increased, 1 isFocused, 2 controlActiveState == .key,
// 3 the list's own FocusState. Red = true, green = false. The rest of the
// row is magenta when selected.

private struct ProbeListFocusedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var probeListFocused: Bool {
        get { self[ProbeListFocusedKey.self] }
        set { self[ProbeListFocusedKey.self] = newValue }
    }
}

struct AccentSelectionProbe: View {
    let selected: Bool
    var listFocused: Bool?
    var unselected: Color = .clear
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.isFocused) private var isFocused
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.probeListFocused) private var envListFocused

    var body: some View {
        if selected {
            HStack(spacing: 0) {
                stripe(prominence == .increased)
                stripe(isFocused)
                stripe(activeState == .key)
                stripe(listFocused ?? envListFocused)
                Color(red: 1, green: 0, blue: 1)
            }
        } else {
            unselected
        }
    }

    private func stripe(_ on: Bool) -> some View {
        (on ? Color(red: 1, green: 0, blue: 0) : Color(red: 0, green: 1, blue: 0))
            .frame(width: 12)
    }
}
