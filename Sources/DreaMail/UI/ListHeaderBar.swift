import SwiftUI

/// Size rules of the search field in the list column's top bar.
enum ListSearchMetrics {
    /// Narrowest the field gets: it shrinks to this before the title truncates.
    static let minWidth: CGFloat = 150
    static let maxWidth: CGFloat = 380
    /// Side padding of the bar; the results panel uses the same trailing edge.
    static let sidePadding: CGFloat = 10
    /// Room left for the window's trailing toolbar buttons (reading-pane
    /// toggle, focus, Ask AI) when the list is the window's last column.
    static let windowButtonsReserve: CGFloat = 170
    /// Widest the results panel gets.
    static let panelMaxWidth: CGFloat = 600
}

/// The list column's top bar: the view's icon and title on the left, the
/// search field (and, while searching, "Search all of Gmail") on the right,
/// with the results panel under the field.
///
/// Drawn by the column itself, over the window's title-bar band, and not as
/// toolbar items: a toolbar item can be moved into the » overflow menu, where
/// a custom view disappears and `/` would focus nothing. This row is always on
/// screen. Applied to every list column (Inbox, labels, saved views,
/// All accounts, Scheduled, Outbox). `/` and the icon strip's search button
/// focus the field via `store.searchFocusToken` / `searchFocusPending`.
struct ListHeaderBar: ViewModifier {
    @Environment(MailStore.self) private var store
    @FocusState private var searchFocused: Bool
    /// Extra trailing space for the window's own toolbar buttons.
    var trailingReserve: CGFloat = 0

    private var searching: Bool {
        !store.committedSearch.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func body(content: Content) -> some View {
        content
            // The title moves into the bar below; the window title stays.
            .toolbar(removing: .title)
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    // The window's toolbar band above this column's content.
                    let band = proxy.safeAreaInsets.top > 0 ? proxy.safeAreaInsets.top : 44
                    ZStack(alignment: .topTrailing) {
                        bar
                            .frame(height: band)
                            .offset(y: -band)
                            .zIndex(1)
                        if store.searchActive {
                            SearchResultsPanel()
                                .frame(maxWidth: ListSearchMetrics.panelMaxWidth,
                                       alignment: .trailing)
                                .padding(.leading, ListSearchMetrics.sidePadding)
                                .padding(.trailing, ListSearchMetrics.sidePadding + trailingReserve)
                                .padding(.top, 4)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("searchResultsPanel")
                                // Snappy fade in place — no slide-in; this app is fast.
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .animation(.easeOut(duration: 0.06), value: store.searchActive)
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: store.selectedView.selectedIcon)
                .foregroundStyle(.mailIcon(selected: false))
                .accessibilityHidden(true)
            Text(store.selectedView.title)
                .font(.headline)
                .lineLimit(1)
                // The field shrinks to its minimum before the title truncates.
                .layoutPriority(2)
                .accessibilityIdentifier("listHeaderTitle")
            Spacer(minLength: 8)
            // While searching, let the user reach past the local cache to Gmail.
            if searching {
                Button { store.searchAllGmail() } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.borderless)
                .disabled(store.serverSearching)
                .help(store.serverSearching ? "Searching…"
                      : "Search all of Gmail — pull matching messages from Gmail, beyond the local cache")
                .accessibilityLabel(store.serverSearching ? "Searching…" : "Search all of Gmail")
                .layoutPriority(1)
            }
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
            .frame(minWidth: ListSearchMetrics.minWidth, maxWidth: ListSearchMetrics.maxWidth)
            .help("Search — from: to: subject: label: has:attachment is:unread is:starred after: before:")
            .accessibilityIdentifier("listSearchField")
            // Gmail's `/`: focus search. A request made while this column was
            // not mounted (compact layout) is honoured when it appears.
            .onChange(of: store.searchFocusToken) { searchFocused = true }
            .onAppear { if store.searchFocusPending { searchFocused = true } }
            // Drive the results panel from the field's focus. Blur is
            // deferred (see noteSearchFocused) so a click on a result row can
            // land before the panel is torn down.
            .onChange(of: searchFocused) {
                if searchFocused { store.searchFocusPending = false }
                store.noteSearchFocused(searchFocused)
            }
        }
        .padding(.leading, ListSearchMetrics.sidePadding + 4)
        .padding(.trailing, ListSearchMetrics.sidePadding + trailingReserve)
    }
}
