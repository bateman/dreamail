import SwiftUI
import AppKit

/// "Check spelling in" rows of Settings ▸ Spelling and grammar: automatic
/// (the macOS setting) or MishMail's own set of languages, chosen among the
/// ones installed on this Mac.
struct ComposeSpellLanguageSettings: View {
    /// Spelling itself is on.
    var enabled: Bool
    @AppStorage(ComposeSpellLanguages.storageKey) private var stored = ""
    @State private var installed: [Choice] = []

    private struct Choice: Identifiable {
        let id: String
        let name: String
    }

    private let checker = SystemSpellLanguageChecker()

    private var chosen: [String]? {
        ComposeSpellLanguages.resolve(stored: stored, checker: checker)
    }

    var body: some View {
        Picker("Check spelling in", selection: specificBinding) {
            Text("Automatic (system languages)").tag(false)
            Text("Specific languages").tag(true)
        }
        .disabled(!enabled)
        .onAppear(perform: loadInstalled)

        if let chosen {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(installed) { choice in
                        let isOn = chosen.contains(choice.id)
                        Toggle(choice.name, isOn: languageBinding(choice.id, chosen: chosen))
                            // At least one: unticking the last would mean
                            // checking nothing, which is what the toggle
                            // above is for.
                            .disabled(!enabled || (isOn && chosen.count == 1))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            Text("Applies while you type. Edit ▸ Spelling and Grammar ▸ Check Document Now and the Spelling panel follow the macOS language setting.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func loadInstalled() {
        installed = checker.availableLanguages
            .map { Choice(id: $0, name: ComposeSpellLanguages.displayName(for: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var specificBinding: Binding<Bool> {
        Binding(
            get: { chosen != nil },
            set: { specific in
                guard specific != (chosen != nil) else { return }
                stored = specific
                    ? ComposeSpellLanguages.encode(ComposeSpellLanguages.defaultSelection(
                        available: checker.availableLanguages,
                        preferred: checker.userPreferredLanguages,
                        current: checker.currentLanguage))
                    : ""
            })
    }

    private func languageBinding(_ code: String, chosen: [String]) -> Binding<Bool> {
        Binding(
            get: { chosen.contains(code) },
            set: { on in
                var next = chosen.filter { $0 != code }
                if on { next.append(code) }
                guard !next.isEmpty else { return }
                stored = ComposeSpellLanguages.encode(next)
            })
    }
}
