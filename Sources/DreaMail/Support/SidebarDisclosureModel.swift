import Foundation
import Observation

/// Open/closed state of the sidebar's disclosure rows, kept in UserDefaults
/// (`SidebarDisclosure`) and mirrored here so a toggle re-renders at once.
/// Shared by the sidebar and its icon strip (`ContentView` owns it), on the
/// main thread.
@Observable
final class SidebarDisclosureModel {
    var moreOpen = SidebarDisclosure.isMoreExpanded() {
        didSet { SidebarDisclosure.setMoreExpanded(moreOpen) }
    }
    /// The dragged order of each sidebar's system views
    /// (`SidebarSystemOrder`); nil is the default.
    private var systemOrders: [SidebarSystemOrder.Scope: [String]?] = [:]

    func systemOrder(_ scope: SidebarSystemOrder.Scope) -> [String]? {
        if let known = systemOrders[scope] { return known }
        return SidebarSystemOrder.stored(scope)
    }

    func setSystemOrder(_ order: [String]?, _ scope: SidebarSystemOrder.Scope) {
        systemOrders[scope] = .some(order)
        SidebarSystemOrder.store(order, scope)
    }
    /// Loaded per account on first use.
    private var expanded: [String: Set<String>] = [:]
    private var labelsMore: [String: Bool] = [:]
    private var accountCollapsed: [String: Bool] = [:]

    func isExpanded(_ node: SidebarLabelNode) -> Bool {
        expandedSet(node.accountId).contains(node.gmailLabelId)
    }

    func setExpanded(_ node: SidebarLabelNode, _ open: Bool) {
        var set = expandedSet(node.accountId)
        if open { set.insert(node.gmailLabelId) } else { set.remove(node.gmailLabelId) }
        expanded[node.accountId] = set
        SidebarDisclosure.setLabel(node.gmailLabelId, accountId: node.accountId, expanded: open)
    }

    private func expandedSet(_ accountId: String) -> Set<String> {
        if let set = expanded[accountId] { return set }
        return SidebarDisclosure.expandedLabels(accountId: accountId)
    }

    func labelsMoreOpen(_ accountId: String) -> Bool {
        labelsMore[accountId]
            ?? SidebarDisclosure.flag(SidebarDisclosure.labelsMoreKey(accountId: accountId))
    }

    func setLabelsMoreOpen(_ accountId: String, _ open: Bool) {
        labelsMore[accountId] = open
        SidebarDisclosure.setFlag(SidebarDisclosure.labelsMoreKey(accountId: accountId), open)
    }

    func accountOpen(_ accountId: String) -> Bool {
        !(accountCollapsed[accountId]
          ?? SidebarDisclosure.flag(SidebarDisclosure.accountCollapsedKey(accountId: accountId)))
    }

    /// Drops what is remembered in memory about a removed account, so adding
    /// it again starts from its (cleared) defaults: "deleted means gone"
    /// (DEC-019, `AccountLifecycle.clearAccountDefaults`).
    func forget(accountId: String) {
        systemOrders[.account(accountId)] = nil
        expanded[accountId] = nil
        labelsMore[accountId] = nil
        accountCollapsed[accountId] = nil
    }

    func setAccountOpen(_ accountId: String, _ open: Bool) {
        accountCollapsed[accountId] = !open
        SidebarDisclosure.setFlag(SidebarDisclosure.accountCollapsedKey(accountId: accountId), !open)
    }
}
