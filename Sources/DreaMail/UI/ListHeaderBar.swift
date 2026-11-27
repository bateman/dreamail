import SwiftUI

/// Where the results panel sits (the row's own sizes are in `ListHeaderLayout`).
enum ListSearchMetrics {
    /// Side padding of the bar; the results panel uses the same trailing edge.
    static let sidePadding: CGFloat = 10
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
    /// The layout the column is rendered in (the `mode` `mailboxLayout` was
    /// given: in centre peek that is `.list` while the stored layout is not).
    var mode: MailLayoutMode = .list
    /// The window's toolbar buttons (one description with the toolbar).
    var windowButtons: [WindowToolbarButton] = []
    /// The system sidebar toggle sits at the row's leading edge.
    var sidebarCollapsed = false

    private var searching: Bool {
        !store.committedSearch.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The title moves into the bar below. From macOS 15 the toolbar title is
    /// removed and the window title stays; on macOS 14 (the app's minimum)
    /// that cannot be done, so the window title is left empty instead of
    /// drawing the title twice on top of each other.
    @ViewBuilder
    private func withoutToolbarTitle(_ content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .navigationTitle(store.selectedView.title)
                .toolbar(removing: .title)
        } else {
            content.navigationTitle("")
        }
    }

    func body(content: Content) -> some View {
        withoutToolbarTitle(content)
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    // The window's toolbar band above this column's content.
                    let band = proxy.safeAreaInsets.top > 0 ? proxy.safeAreaInsets.top : 44
                    let layout = ListHeaderLayout.resolve(
                        columnWidth: proxy.size.width,
                        buttonsOverRow: ListHeaderLayout.windowButtonsOverRow(mode: mode)
                            ? windowButtons : [],
                        sidebarToggleOverRow: sidebarCollapsed,
                        searching: searching)
                    ZStack(alignment: .topTrailing) {
                        bar(layout)
                            .frame(height: band)
                            .offset(y: -band)
                            .zIndex(1)
                            // Read before the list rows: it is an overlay.
                            .accessibilitySortPriority(10)
                        if store.searchActive {
                            SearchResultsPanel()
                                .frame(maxWidth: ListSearchMetrics.panelMaxWidth,
                                       alignment: .trailing)
                                .padding(.leading, ListSearchMetrics.sidePadding)
                                .padding(.trailing, ListSearchMetrics.sidePadding)
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

    private func bar(_ layout: ListHeaderLayout.Result) -> some View {
        HStack(spacing: ListHeaderLayout.spacing) {
            HStack(spacing: ListHeaderLayout.spacing) {
                Image(systemName: store.selectedView.selectedIcon)
                    .foregroundStyle(.mailIcon(selected: false))
                    .accessibilityHidden(true)
                Text(store.selectedView.title)
                    .font(.headline)
                    .lineLimit(1)
                    // Never below its guaranteed width; truncates last.
                    .frame(minWidth: layout.titleMinWidth, alignment: .leading)
                    .accessibilityIdentifier("listHeaderTitle")
            }
            // The field shrinks to its minimum before the title truncates.
            .layoutPriority(2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("listHeaderLeading")
            Spacer(minLength: ListHeaderLayout.spacing)
            // While searching, let the user reach past the local cache to Gmail.
            if searching {
                Button { store.searchAllGmail() } label: {
                    if layout.showsSearchAllText {
                        Label("Search Gmail", systemImage: "magnifyingglass.circle")
                    } else {
                        Image(systemName: "magnifyingglass.circle")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(store.serverSearching)
                .help(store.serverSearching ? "Searching…"
                      : "Search all of Gmail — pull matching messages from Gmail, beyond the local cache")
                .accessibilityLabel(store.serverSearching ? "Searching…" : "Search all of Gmail")
                .accessibilityIdentifier("listSearchAll")
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
            .frame(minWidth: layout.fieldMinWidth, maxWidth: layout.fieldMaxWidth)
            .help("Search — from: to: subject: label: has:attachment is:unread is:starred after: before:")
            // One element for the whole field box (its children keep their own).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("listSearchBox")
            // Gmail's `/`: focus search. A request made while this column was
            // not mounted (compact layout) is honoured when it appears.
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
            // Unmounted while focused (layout switch): end the search-active
            // state, or the key monitor keeps swallowing arrows and Enter.
            .onDisappear { store.dismissSearchPanel() }
            // Drive the results panel from the field's focus. Blur is
            // deferred (see noteSearchFocused) so a click on a result row can
            // land before the panel is torn down.
            .onChange(of: searchFocused) {
                if searchFocused { store.searchFocusPending = false }
                store.noteSearchFocused(searchFocused)
            }
        }
        .padding(.leading, ListHeaderLayout.leadingPadding + layout.reserve)
        .padding(.trailing, ListHeaderLayout.trailingPadding)
    }
}
