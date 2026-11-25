import Foundation

/// Which account Settings ▸ Gmail filters shows. Filters belong to one
/// account, and the pane shows one at a time: the one chosen (in the pane
/// or from Settings ▸ Accounts) while it is still an account; otherwise, as
/// Gmail's settings follow the open mailbox, the account selected in the
/// main window; otherwise the first.
enum FiltersPaneAccount {
    static func shown(chosen: String?, active: String?, accounts: [String]) -> String? {
        if let chosen, accounts.contains(chosen) { return chosen }
        if let active, accounts.contains(active) { return active }
        return accounts.first
    }
}
