import SwiftUI

/// Where the search field sits in the list column's top bar and how wide it is.
enum ListSearchMetrics {
    /// Narrowest the field gets before the toolbar would have to drop it; the
    /// narrowest list column (420 pt) still fits title, glyph and this.
    static let minWidth: CGFloat = 150
    static let idealWidth: CGFloat = 260
    static let maxWidth: CGFloat = 380
}

/// The search field in the top bar of the list column (right of the view's
/// icon and title), with the results panel under it. Applied to every list
/// column: Inbox, labels, saved views, All accounts, Scheduled, Outbox.
/// `/` (and the icon strip's search button) focus it via `store.searchFocusToken`.
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
                    .frame(minWidth: ListSearchMetrics.minWidth,
                           idealWidth: ListSearchMetrics.idealWidth,
                           maxWidth: ListSearchMetrics.maxWidth)
                    .help("Search — from: to: subject: label: has:attachment is:unread is:starred after: before:")
                    .accessibilityIdentifier("listSearchField")
                    // Gmail's `/`: focus search.
                    .onChange(of: store.searchFocusToken) { searchFocused = true }
                    // Drive the results panel from the field's focus. Blur is
                    // deferred (see noteSearchFocused) so a click on a result
                    // row can land before the panel is torn down.
                    .onChange(of: searchFocused) { store.noteSearchFocused(searchFocused) }
                }
            }
            // Command-K-style panel, floated over the top of the list column
            // (it spills over the rows, not past the column).
            .overlay(alignment: .topLeading) {
                if store.searchActive {
                    SearchResultsPanel()
                        .frame(maxWidth: 600, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                        // Snappy fade in place — no slide-in; this app is fast.
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.06), value: store.searchActive)
    }
}
