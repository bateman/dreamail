import Foundation

extension MailStore {
    /// Gmail's "New label" dialog (the "+" next to the sidebar's Labels):
    /// creates `name`, nested under `parent` when one is given (Gmail's
    /// "Nest label under"), on `accountId`. Nothing is applied to any
    /// conversation. Returns nil on success, else the reason, for the
    /// dialog to show.
    func createLabel(name: String, parent: String?, accountId: String) async -> String? {
        guard !demoMode else { return "Creating labels is disabled in the demo inbox." }
        // Checked again here, not only in the dialog: the parent must be one
        // of this account's own labels.
        let rows = userLabels(forAccount: accountId)
        let full: String
        switch NewLabelName.check(name: name, nest: parent != nil, parent: parent ?? "", rows: rows) {
        case .ok(let value): full = value
        case .empty: return "Enter a label name."
        case .duplicate: return "A label with this name already exists."
        case .unknownParent: return "Choose a label of this account to nest it under."
        }
        // The owner's rule: a sublabel starts with its parent's Gmail color
        // (Gmail itself gives a new sublabel no color).
        let parentRow = parent.flatMap { p in rows.first { $0.name == p } }
        let created: GLabel
        do {
            created = try await client(for: accountId).createLabel(
                name: full, color: parentRow.flatMap(Self.gmailColor(of:)))
        } catch {
            return error.localizedDescription
        }
        let row = LabelRow.created(created, accountId: accountId)
        do {
            try await db.write { db in try row.save(db) }
        } catch {
            // Created on Gmail all the same: the next sync brings it in.
            // Close the dialog (a second Create would be refused by Gmail)
            // and say so.
            reloadAccounts()
            showNotice("The label was created on Gmail. It appears here after the next sync.")
            return nil
        }
        reloadAccounts()
        return nil
    }

    /// A label's Gmail color as drawn (pair or preset, DEC-071), as one
    /// the API accepts, or nil. Every preset pair is in Gmail's palette.
    nonisolated static func gmailColor(of row: LabelRow) -> GmailLabelColor? {
        row.inheritableGmailColor
    }
}
