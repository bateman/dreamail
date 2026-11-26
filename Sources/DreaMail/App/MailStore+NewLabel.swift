import Foundation

extension LabelRow {
    /// The row for a label this app has just created on Gmail.
    static func created(_ l: GLabel, accountId: String) -> LabelRow {
        LabelRow(id: "\(accountId):\(l.id)", accountId: accountId,
                 gmailLabelId: l.id, name: l.name, type: l.type ?? "user",
                 color: nil,
                 gmailBackgroundColor: LabelRGB.gmailHex(l.color?.backgroundColor),
                 gmailTextColor: LabelRGB.gmailHex(l.color?.textColor),
                 listVisibility: l.labelListVisibility,
                 messageListVisibility: l.messageListVisibility)
    }
}

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
        // The owner's rule: a sublabel starts with its parent's colors, both
        // the one on Gmail and the one only on this Mac (Gmail itself gives
        // a new sublabel no color).
        let parentRow = parent.flatMap { p in rows.first { $0.name == p } }
        let created: GLabel
        do {
            created = try await client(for: accountId).createLabel(
                name: full, color: parentRow.flatMap(Self.gmailColor(of:)))
        } catch {
            return error.localizedDescription
        }
        var fresh = LabelRow.created(created, accountId: accountId)
        fresh.color = parentRow?.color
        let row = fresh
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

    /// A label's Gmail color as one the API accepts, or nil.
    nonisolated static func gmailColor(of row: LabelRow) -> GmailLabelColor? {
        GmailLabelColor(background: row.gmailBackgroundColor, text: row.gmailTextColor)
    }
}
