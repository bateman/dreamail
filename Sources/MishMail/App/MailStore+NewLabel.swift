import Foundation

extension LabelRow {
    /// The row for a label this app has just created on Gmail.
    static func created(_ l: GLabel, accountId: String) -> LabelRow {
        LabelRow(id: "\(accountId):\(l.id)", accountId: accountId,
                 gmailLabelId: l.id, name: l.name, type: l.type ?? "user",
                 color: nil,
                 gmailBackgroundColor: LabelRGB.normalizedHex(l.color?.backgroundColor),
                 gmailTextColor: LabelRGB.normalizedHex(l.color?.textColor),
                 listVisibility: l.labelListVisibility)
    }
}

extension MailStore {
    /// Gmail's "New label" dialog (the "+" next to the sidebar's Labels):
    /// creates `name`, nested under `parent` when one is given (Gmail's
    /// "Nest label under"), on `accountId`. Nothing is applied to any
    /// conversation. Returns false, with the reason in `lastError`, when
    /// Gmail refuses.
    @discardableResult
    func createLabel(name: String, parent: String?, accountId: String) async -> Bool {
        guard !demoMode else {
            showNotice("Creating labels is disabled in the demo inbox")
            return false
        }
        guard let fullName = NewLabelName.full(name: name, parent: parent) else { return false }
        do {
            let l = try await client(for: accountId).createLabel(name: fullName)
            let row = LabelRow.created(l, accountId: accountId)
            _ = try? await db.write { db in try row.save(db) }
            reloadAccounts()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
