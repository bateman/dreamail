import SwiftUI

/// The search field as a toolbar item of the list column: right of the view's
/// icon and title, with the results panel under it. A real toolbar item, so it
/// takes the mouse like any other. Applied to every list column (Inbox,
/// labels, saved views, All accounts, Scheduled, Outbox).
///
/// Not `.searchable`: programmatic focus is needed (macOS 14). `/` and the
/// icon strip's search button focus it via `store.searchFocusToken` /
/// `searchFocusPending`.
///
/// The item is flexible (`ListHeaderLayout`: ideal 260 pt, minimum 140 pt), so
/// the system narrows the field before it would overflow anything.
struct ListSearchToolbar: ViewModifier {
    @Environment(MailStore.self) private var store
    @FocusState private var searchFocused: Bool

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    SearchField(prompt: "Search", text: Bindable(store).searchText,
                                focused: $searchFocused, emphasized: searchFocused,
                                onSubmit: {
                        // Fallback path — with the dropdown open, Enter is handled
                        // by the key monitor and routed to the panel instead.
                        store.commitSearch(store.searchText)
                        store.dismissSearchPanel()
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        if store.selectedThreadId == nil { store.moveSelection(1) }
                    })
                    .frame(minWidth: ListHeaderLayout.fieldMinWidth,
                           idealWidth: ListHeaderLayout.fieldIdealWidth,
                           maxWidth: ListHeaderLayout.fieldMaxWidth)
                    .help("Search — from: to: subject: label: has:attachment is:unread is:starred after: before:")
                    // One element for the whole field box (its children keep their own).
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("listSearchBox")
                    // Gmail's `/`: focus search. A request made while this column
                    // was not mounted (compact layout) is honoured when it appears.
                    .onChange(of: store.searchFocusToken) {
                        searchFocused = true
                        store.searchFocusPending = false
                    }
                    .onAppear {
                        guard store.searchFocusPending else { return }
                        // Not if something else took the keyboard meanwhile.
                        if store.searchFocusStillWanted { searchFocused = true }
                        else { store.searchFocusPending = false }
                    }
                    // Unmounted while focused (layout switch): end the
                    // search-active state, or the key monitor keeps swallowing
                    // arrows and Enter.
                    .onDisappear { store.dismissSearchPanel() }
                    // Drive the results panel from the field's focus. Blur is
                    // deferred (see noteSearchFocused) so a click on a result
                    // row can land before the panel is torn down.
                    .onChange(of: searchFocused) {
                        if searchFocused { store.searchFocusPending = false }
                        store.noteSearchFocused(searchFocused)
                    }
                }
            }
            // Command-K-style panel, floated over the top of the list column
            // under the field, at the column's trailing edge (the field's
            // side), never wider than the column.
            .overlay(alignment: .topTrailing) {
                if store.searchActive {
                    SearchResultsPanel()
                        .frame(maxWidth: 600, alignment: .trailing)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("searchResultsPanel")
                        // Snappy fade in place — no slide-in; this app is fast.
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.06), value: store.searchActive)
    }
}
