import SwiftUI

/// Gmail-style "l" label picker for the selected thread: type to filter,
/// up/down to move, Enter applies the highlighted label and closes, Space or click toggles
/// without closing, Esc closes. Opened
/// with `v` it is Gmail's "Move to": the pick adds the label, removes the
/// conversation (or the checked ones) from the inbox and closes.
/// (Space only toggles after arrow navigation; while typing it stays a
/// literal space so multi-word label names remain searchable.)
///
/// The highlight index lives in LabelPickerState and is driven by the
/// window-level key monitor in ContentView — the text field's field editor
/// consumes arrow and Return events before SwiftUI's onKeyPress ever sees
/// them, so handling them here doesn't work while the field is focused.
/// (That's also why there's no .onSubmit: Return is committed by the
/// monitor, which sees the event first regardless of focus.)
struct LabelPicker: View {
    @Environment(MailStore.self) var store
    // `store.selectedThread` reads selection, which no longer publishes
    // through MailStore (it lives on ListFocusState). Observe listFocus so a
    // focus-only change can't leave this body stale. Cheap: the picker is
    // mounted only while open.
    @EnvironmentObject var listFocus: ListFocusState
    // Observed separately from MailStore so per-keystroke query/highlight
    // changes re-render only this view, not the whole window.
    @ObservedObject var picker: LabelPickerState
    @FocusState private var focused: Bool
    /// Gmail's "Create new" footer row: the same sheet as the sidebar's "+".
    @State private var newLabel: NewLabelRequest?

    /// Stable id for the "Create …" row so ScrollViewReader can find it
    /// after the filtered list shrinks (index-based ids churn under filter).
    private static let createRowID = "label-picker-create"

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { store.mailboxOverlay = nil }

            if let thread = store.labelPickerThread {
                let labels = store.labelPickerLabels(for: thread)
                // The "Create …" row sits after the matches and is reachable
                // with the same up/down highlight.
                let createName = store.labelPickerCreateName(for: thread)
                let rowCount = labels.count + (createName != nil ? 1 : 0)
                let highlighted = min(picker.highlight, max(rowCount - 1, 0))
                VStack(spacing: 0) {
                    // Gmail's header: a title, then the filter field with a
                    // magnifier and an accent underline.
                    Text(title)
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.top, 10)
                    HStack(spacing: 6) {
                        TextField(placeholder, text: $picker.query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
                            .focused($focused)
                            .accessibilityLabel(title)
                            .accessibilityIdentifier("labelPicker.search")
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(.accentForeground).frame(height: 2)
                    }
                    .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
                    if store.accounts.count > 1 {
                        Text(thread.accountId)
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.bottom, 6)
                    }
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            // Eager VStack (not LazyVStack): the Labels filter
                            // chip uses the same pattern. Lazy stacks + index
                            // scrollTo leave rows past the fold unmaterialized,
                            // so typing a name for a label further down looked
                            // empty even when the filter matched.
                            VStack(spacing: 0) {
                                ForEach(Array(labels.enumerated()), id: \.element.id) { idx, label in
                                    let applied = thread.labels.contains(label.gmailLabelId)
                                    HStack(spacing: 8) {
                                        if picker.mode == .label {
                                            Image(systemName: applied ? "checkmark.square.fill" : "square")
                                                .foregroundStyle(applied ? AnyShapeStyle(.accentForeground) : AnyShapeStyle(.secondary))
                                        }
                                        LabelDot(colors: store.labelColors(label.name, account: label.accountId),
                                                 size: 8)
                                        Text(LabelSearch.highlighted(label.name, query: picker.query))
                                            .font(.system(size: 13))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(.accentFill.opacity(idx == highlighted ? 0.18 : 0))
                                    .contentShape(Rectangle())
                                    .onTapGesture { store.labelPickerCommit(label, thread: thread) }
                                    .onHover { if $0 { picker.highlight = idx } }
                                    .id(label.id)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(label.name)
                                    .accessibilityValue(picker.mode == .label ? (applied ? "on" : "off") : "")
                                    .accessibilityHint(picker.mode == .label
                                        ? "Click to toggle. Return applies and closes; Space toggles."
                                        : "Return moves here.")
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityIdentifier("labelPicker.row.\(label.name)")
                                }
                                if let createName {
                                    HStack(spacing: 8) {
                                        Image(systemName: "plus.circle")
                                            .foregroundStyle(highlighted == labels.count ? AnyShapeStyle(.accentForeground) : AnyShapeStyle(.secondary))
                                        Text("Create “\(createName)”").font(.system(size: 13))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(.accentFill.opacity(highlighted == labels.count ? 0.18 : 0))
                                    .contentShape(Rectangle())
                                    .onTapGesture { store.createLabelAndApply(name: createName, thread: thread) }
                                    .onHover { if $0 { picker.highlight = labels.count } }
                                    .id(Self.createRowID)
                                }
                                if labels.isEmpty, createName == nil {
                                    Text("No labels in \(thread.accountId)").font(.caption).foregroundStyle(.secondary)
                                        .padding(12)
                                }
                                // A matching label on another account can't be
                                // applied here — say so instead of silently
                                // dropping it from the results.
                                if let other = store.labelPickerOtherAccountMatch(excluding: thread.accountId) {
                                    Text("“\(other.name)” is a label in \(other.accountId) — labels apply per account")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                }
                            }
                        }
                        .frame(maxHeight: 260)
                        .onChange(of: picker.highlight) {
                            // Keep the monitor-driven index in bounds and visible.
                            if picker.highlight > max(rowCount - 1, 0) {
                                picker.highlight = max(rowCount - 1, 0)
                            }
                            scrollToHighlighted(proxy, labels: labels, createName: createName,
                                                highlight: picker.highlight)
                        }
                        .onChange(of: picker.query) {
                            // Typing resets selection to the first match. Must
                            // scroll even when highlight was already 0 — otherwise
                            // a prior mouse-wheel offset leaves the short
                            // filtered list above the viewport (blank picker).
                            picker.highlight = 0
                            // Defer until after the filtered ForEach commits so
                            // the stable row id exists for scrollTo.
                            DispatchQueue.main.async {
                                scrollToHighlighted(proxy, labels: store.labelPickerLabels(for: thread),
                                                    createName: store.labelPickerCreateName(for: thread),
                                                    highlight: 0)
                            }
                        }
                    }
                    Divider()
                    if picker.mode == .label {
                        Button {
                            newLabel = NewLabelRequest(accountId: thread.accountId, parent: nil)
                        } label: {
                            Text("Create new")
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("labelPicker.createNew")
                        Divider()
                    }
                    // Spell out the keyboard model: Enter applies and closes
                    // (creates, on the Create row); Space toggles and stays.
                    HStack(spacing: 10) {
                        ForEach(LabelPickerKeyRules.footerHints(
                            mode: picker.mode,
                            onCreateRow: highlighted == labels.count && createName != nil),
                                id: \.self) { Text($0) }
                        Spacer()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .frame(width: 380)
                .shadow(radius: 24)
                .padding(.top, 130)
                .sheet(item: $newLabel) { NewLabelSheet(request: $0) }
                .onAppear { focused = true }
                .onChange(of: focused) {
                    // When the field finally wins focus, macOS selects all —
                    // the next keystroke would replace text the key monitor
                    // already routed into the query. Park the caret at the end.
                    guard focused, !picker.query.isEmpty else { return }
                    DispatchQueue.main.async {
                        if let editor = NSApp.keyWindow?.fieldEditor(false, for: nil) as? NSTextView {
                            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
                        }
                    }
                }
            }
        }
    }

    private var title: String { picker.mode == .move ? "Move to:" : "Label as:" }

    /// "Move 5 conversations to…" when the move covers several.
    private var placeholder: String {
        guard picker.mode == .move else { return "" }
        let n = picker.moveTargetIds.count
        return n > 1 ? "Move \(n) conversations to…" : "Move to…"
    }

    /// Scroll the list so the highlighted row (label or Create) is visible.
    private func scrollToHighlighted(_ proxy: ScrollViewProxy, labels: [LabelRow],
                                     createName: String?, highlight: Int) {
        let rowCount = labels.count + (createName != nil ? 1 : 0)
        guard rowCount > 0 else { return }
        let idx = min(max(highlight, 0), rowCount - 1)
        if idx < labels.count {
            proxy.scrollTo(labels[idx].id, anchor: .center)
        } else {
            proxy.scrollTo(Self.createRowID, anchor: .center)
        }
    }
}
