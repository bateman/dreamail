import SwiftUI
import AppKit

extension AccountRailPalette {
    static let background = Color(nsColor: .adaptive(light: backgroundLight, dark: backgroundDark))
    static let glyph = Color(nsColor: .adaptive(light: glyphLight, dark: glyphDark))
}

/// The always-visible strip left of the sidebar: one avatar per account
/// (ring, unread badge), "All accounts" first when there are several, a "+"
/// to add an account, and at the bottom the Settings button.
struct AccountRail: View {
    /// Avatar 40 pt + 12 pt padding on each side.
    static let avatarSize: CGFloat = 40
    static let width: CGFloat = 64

    @Environment(MailStore.self) var store
    private var bound: Bindable<MailStore> { Bindable(store) }
    /// Id of the account being dragged, for the live reorder.
    @State private var draggingAccountId: String?

    var body: some View {
        VStack(spacing: 0) {
            // Many accounts scroll; the bottom area stays put.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    if store.accounts.count > 1 { allEntry }
                    ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                        accountEntry(account, shortcut: index + 2)
                            .onDrag {
                                draggingAccountId = account.id
                                return NSItemProvider(object: account.id as NSString)
                            }
                            .onDrop(of: [.text], delegate: AccountDropDelegate(
                                target: account, draggingId: $draggingAccountId, store: store))
                    }
                    addButton
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
            }
            bottomArea
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // Behind the title bar too, so there is no seam under the traffic
        // lights.
        .background(AccountRailPalette.background.ignoresSafeArea())
        // A drop outside an account avatar still clears the dragged id.
        .onDrop(of: [.text], isTargeted: nil) { _ in
            draggingAccountId = nil
            return true
        }
        .sheet(isPresented: bound.editingAccountLabels) {
            AccountLabelsEditor()
        }
    }

    // MARK: - Entries

    private var allEntry: some View {
        let selected = store.activeAccountId == nil
        return Button {
            store.setActiveAccount(nil)
        } label: {
            Image(systemName: "tray.2.fill")
                .font(.system(size: 17))
                .foregroundStyle(AccountRailPalette.glyph)
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .background(Circle().fill(AccountRailPalette.glyph.opacity(0.14)))
                .overlay {
                    if selected {
                        Circle().strokeBorder(AccountRailPalette.glyph,
                                              lineWidth: AccountAvatarView.emphasizedRingWidth)
                    }
                }
                .opacity(selected ? 1 : 0.6)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("All accounts (⌘1)")
        .accessibilityLabel("All accounts")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("accountRail.all")
    }

    private func accountEntry(_ account: Account, shortcut: Int) -> some View {
        // With one account the unified entry is hidden, so it is the selection.
        let selected = store.activeAccountId == account.id || store.accounts.count == 1
        let unread = store.accountUnread[account.id] ?? 0
        let title = AccountLabelColor.title(account)
        let needsReauth = store.accountsNeedingReauth.contains(account.id)
        let tooltip = [title, account.id, unread > 0 ? "\(unread) unread" : nil]
            .compactMap { $0 }.joined(separator: " · ")
            + (shortcut <= 9 ? " (⌘\(shortcut))" : "")
        return Button {
            store.setActiveAccount(account.id)
        } label: {
            AccountAvatarView(
                name: title, key: account.id, size: Self.avatarSize,
                photo: store.accountPhotos[account.id],
                ring: .init(storedHex: account.labelColor, surface: .rail),
                decorative: true, unread: unread,
                emphasized: selected, dimmed: !selected)
                .overlay(alignment: .bottomTrailing) {
                    if needsReauth {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                            .padding(1.5)
                            .background(Circle().fill(AccountRailPalette.background))
                            .offset(x: 3, y: 3)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(needsReauth ? tooltip + " — needs to be reauthorized" : tooltip)
        .accessibilityLabel("\(title), \(account.id)")
        .accessibilityValue([unread > 0 ? "\(unread) unread" : nil,
                             needsReauth ? "needs reauthorization" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(store.accounts.count > 1 ? "Drag to reorder" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("accountRail.account.\(account.id)")
        .contextMenu {
            if needsReauth {
                Button("Reauthorize…") { store.addAccount(reauthorizing: account.id) }
                    .disabled(store.connectingAccount)
            }
            Button("Edit Account Labels…") { store.editingAccountLabels = true }
            Button(store.connectingAccount ? "Connecting…" : "Add Google Account…") {
                store.addAccount()
            }
            .disabled(store.connectingAccount)
        }
    }

    private var addButton: some View {
        Button {
            store.addAccount()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AccountRailPalette.glyph)
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .overlay(Circle().strokeBorder(AccountRailPalette.glyph.opacity(0.5),
                                               style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(store.connectingAccount)
        .help(store.connectingAccount ? "Connecting…" : "Add Google Account…")
        .accessibilityLabel("Add Google Account")
        .accessibilityIdentifier("accountRail.add")
    }

    // MARK: - Bottom area

    /// Grows upward: the gear is last; a later link (contacts, chat,
    /// calendar) goes in the stack above it, one line each.
    private var bottomArea: some View {
        VStack(spacing: 8) {
            Rectangle()
                .fill(AccountRailPalette.glyph.opacity(0.15))
                .frame(width: Self.avatarSize, height: 1)
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .foregroundStyle(AccountRailPalette.glyph)
                    .frame(width: Self.avatarSize, height: Self.avatarSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("accountRail.settings")
        }
        .padding(.bottom, 10)
    }
}

/// Live-reorders the rail as a dragged avatar crosses a neighbor — the
/// standard SwiftUI reorderable pattern (`List.onMove` is not available in a
/// plain stack).
struct AccountDropDelegate: DropDelegate {
    let target: Account
    @Binding var draggingId: String?
    let store: MailStore

    func dropEntered(info: DropInfo) {
        guard let draggingId, draggingId != target.id,
              let from = store.accounts.firstIndex(where: { $0.id == draggingId }),
              let to = store.accounts.firstIndex(where: { $0.id == target.id }) else { return }
        store.reorderAccounts(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        return true
    }
}
