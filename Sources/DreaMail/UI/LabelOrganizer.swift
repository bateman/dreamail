import SwiftUI

/// Organize labels: drag to reorder and pick a color per label. The order is
/// local. A label has two colors: its color on Gmail (written with
/// labels.patch, shown on the web and the phone too) and an optional
/// Mac-only color that is never sent to Gmail and wins on display (DEC-023).
/// They drive the label pills, the Labels filter dropdown, and the "l"
/// picker everywhere in the app.
struct LabelOrganizer: View {
    @Environment(MailStore.self) var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAccount: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Organize Labels")
                    .font(.headline)
                Spacer()
                // With more than one account, labels are scoped per account
                // (Gmail ids don't cross accounts).
                if store.accounts.count > 1 {
                    Picker("", selection: $selectedAccount) {
                        ForEach(store.accounts) { account in
                            Text(AccountLabelColor.title(account)).tag(String?.some(account.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)

            Text("Drag to reorder (only on this Mac); sublabels move with their label and stay under it. Click a swatch to change the color on Gmail, or set a color only on this Mac. A label's color also goes to its sublabels.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 8)

            Divider()

            let account = resolvedAccount
            let labels = account.map { store.userLabels(forAccount: $0) } ?? []
            let entries = LabelOrganizerOrder.entries(
                tree: account.flatMap { store.labelTrees[$0] } ?? [], rows: labels)
            if labels.isEmpty {
                ContentUnavailableView("No labels",
                                       systemImage: "tag",
                                       description: Text("Labels you create in Gmail show up here."))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                List {
                    ForEach(entries) { entry in
                        LabelOrganizerRow(entry: entry)
                    }
                    .onMove { source, destination in
                        // A drop that would leave the label's family (or land
                        // inside another) is refused: the row goes back.
                        if let account, source.count == 1, let from = source.first,
                           let order = LabelOrganizerOrder.moved(entries, from: from, to: destination) {
                            store.reorderLabels(account: account, to: order)
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 260)
            }

            Divider()
            HStack {
                Button("Use Gmail's Order") {
                    if let account { store.resetLabelOrder(account: account) }
                }
                .disabled(!labels.contains { $0.sortOrder != LabelRow.unsorted })
                .help("Forget the order set here for this account's labels and list them as Gmail does.")
                .accessibilityIdentifier("labelOrganizer.useGmailOrder")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 440, height: 480)
        // Escape closes it: "Done" is only the default action.
        .onExitCommand { dismiss() }
        .onAppear {
            if selectedAccount == nil {
                selectedAccount = store.activeAccountId ?? store.accounts.first?.id
            }
        }
    }

    private var resolvedAccount: String? {
        selectedAccount ?? store.activeAccountId ?? store.accounts.first?.id
    }
}

/// One organizer row: a color swatch (opens a palette), the label name, and a
/// drag handle courtesy of List's move support.
private struct LabelOrganizerRow: View {
    @Environment(MailStore.self) var store
    let entry: LabelOrganizerEntry
    private var label: LabelRow { entry.row }
    @State private var showPalette = false

    var body: some View {
        HStack(spacing: 10) {
            Button { showPalette = true } label: {
                LabelDot(colors: label.displayColors, size: 18)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPalette, arrowEdge: .bottom) {
                LabelColorPalette(label: label) { showPalette = false }
            }

            Text(entry.displayName).font(.system(size: 13))
                .help(label.name)
                .accessibilityLabel(label.name)
                .accessibilityIdentifier("labelOrganizer.name.\(label.id)")
            Spacer()
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .padding(.leading, CGFloat(entry.depth) * 18)
    }
}

/// The label color popover, in two parts that stay apart: the color on
/// Gmail (Gmail's own palette, synced) and the color only on this Mac
/// (local, never sent, shown instead of the Gmail color while set).
/// Also opened from the sidebar's label menu ("Label color").
struct LabelColorPalette: View {
    @Environment(MailStore.self) var store
    let label: LabelRow
    let onPick: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 8), count: 6)
    private let gmailColumns = Array(repeating: GridItem(.fixed(22), spacing: 5),
                                     count: GmailLabelPalette.columns)

    var body: some View {
        let saving = store.gmailLabelColorSaving.contains(label.id)
        VStack(alignment: .leading, spacing: 10) {
            Text("Color on Gmail").font(.system(size: 12, weight: .semibold))
            Text("Also shown in Gmail on the web and on your phone.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            LazyVGrid(columns: gmailColumns, spacing: 5) {
                ForEach(GmailLabelPalette.swatches, id: \.self) { swatch in
                    Button {
                        store.setGmailLabelColor(label, to: swatch)
                        onPick()
                    } label: {
                        LabelDot(colors: swatch.colors, size: 20)
                            .overlay {
                                if label.gmailBackgroundColor == swatch.background {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(LabelRGB(hexString: swatch.text).map(Color.init) ?? .primary)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(swatch.background)
                    .accessibilityLabel("Color on Gmail \(swatch.background)")
                    .accessibilityIdentifier("labelColor.gmail.\(swatch.background)")
                    .accessibilityAddTraits(label.gmailBackgroundColor == swatch.background ? .isSelected : [])
                }
            }
            .disabled(saving)
            Button {
                store.setGmailLabelColor(label, to: nil)
                onPick()
            } label: {
                Label("No color on Gmail", systemImage: "circle.slash")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(saving || !label.hasGmailColor)
            CurrentColorLine(text: LabelCurrentColor.gmail(label),
                             colors: LabelColors(background: label.gmailBackgroundColor,
                                                 text: label.gmailTextColor),
                             identifier: "labelColor.current.gmail")
            if saving {
                Text("Saving to Gmail…").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if LabelRGB.normalizedHex(label.color) != nil {
                Text("A color only on this Mac is set and is shown instead.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Divider()
            Text("Only on this Mac").font(.system(size: 12, weight: .semibold))
            Text("Never sent to Gmail.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Color.labelPalette, id: \.hex) { swatch in
                    Button {
                        store.setLabelColor(label, hex: swatch.hex)
                        onPick()
                    } label: {
                        Circle()
                            .fill(LabelRGB(hexString: swatch.hex).map(Color.init) ?? .gray)
                            .frame(width: 24, height: 24)
                            .overlay {
                                if label.color?.caseInsensitiveCompare(swatch.hex) == .orderedSame {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(swatch.name)
                    .accessibilityLabel("Color only on this Mac: \(swatch.name)")
                    .accessibilityIdentifier("labelColor.mac.\(swatch.hex)")
                    .accessibilityAddTraits(label.color?.caseInsensitiveCompare(swatch.hex) == .orderedSame
                                            ? .isSelected : [])
                }
            }
            CurrentColorLine(text: LabelCurrentColor.local(label, palette: Color.labelPalette.map { $0.hex }),
                             colors: LabelColors(background: label.color, text: nil),
                             identifier: "labelColor.current.mac")
            Button {
                store.setLabelColor(label, hex: nil)
                onPick()
            } label: {
                Label("Gmail color", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(label.color == nil)
            .help("Remove the Mac-only color and show the color on Gmail")
        }
        .padding(12)
        .frame(width: 244)
    }
}

/// "Current: <swatch> #rrggbb": the stored color as text (and a swatch when
/// there is one), readable by VoiceOver and UI tests.
private struct CurrentColorLine: View {
    let text: String
    let colors: LabelColors
    let identifier: String

    var body: some View {
        HStack(spacing: 6) {
            if colors.isColored { LabelDot(colors: colors, size: 12) }
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityIdentifier(identifier)
    }
}
