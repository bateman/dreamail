import AppKit

/// One entry of a signature-default pop-up: what it shows and what picking it
/// stores.
struct SignatureDefaultItem {
    let title: String
    let value: SignatureDefaultChoice
}

/// The pop-up's items, kept apart from the view so they are unit-tested.
enum SignatureDefaultItems {
    /// One menu item per entry, in order, even when titles repeat
    /// (`addItem(withTitle:)` would drop the earlier item of the same title
    /// and shift every index after it).
    static func fill(_ button: NSPopUpButton, with items: [SignatureDefaultItem]) {
        button.removeAllItems()
        for item in items {
            button.menu?.addItem(NSMenuItem(title: item.title, action: nil, keyEquivalent: ""))
        }
    }

    /// The choice of the item now selected.
    static func pick(_ button: NSPopUpButton, from items: [SignatureDefaultItem]) -> SignatureDefaultChoice? {
        let index = button.indexOfSelectedItem
        return items.indices.contains(index) ? items[index].value : nil
    }
}
