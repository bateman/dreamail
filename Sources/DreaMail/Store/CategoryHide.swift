import Foundation
import GRDB

/// Category-tab exclusion for thread lists.
///
/// Extracted from `MailStore` so hostless unit tests share the exact SQL
/// (no AppKit) — same pattern as `SidebarCounts`. Hiding a category removes
/// unstarred mail in that tab; a star is an explicit pin and always survives.
///
/// `keepIds` are threads that were just unstarred under an active hide (or
/// other star-gated list). Under category hide, pins are thread-long (drop
/// when selection leaves); under Starred / is:starred they are session-long
/// (until view/filter change). See `StarStickiness`.
enum CategoryHide {
    /// Hide the given Gmail categories (`CATEGORY_PROMOTIONS`, …), keeping
    /// starred threads (and stickied `keepIds`) visible. Prefer denorm flags
    /// for promo/social; fall back to `labelIds LIKE` for Updates/Forums (no
    /// denorm columns yet).
    static func apply(
        _ query: QueryInterfaceRequest<MailThread>,
        hide: Set<String>,
        keepIds: [String] = [],
        exemptAccounts: Set<String> = []
    ) -> QueryInterfaceRequest<MailThread> {
        var q = query
        // Promotions and Social are never hidden for the exempt accounts
        // (`CategoryRows`: the setting is off). Built only when there are some.
        func tabClear(_ flag: String) -> SQLExpression {
            let clear: SQLExpression = Column(flag) == false
            return exemptAccounts.isEmpty
                ? clear : clear || exemptAccounts.contains(Column("accountId"))
        }
        for cat in hide {
            switch cat {
            case "CATEGORY_PROMOTIONS":
                q = q.filter(tabClear("inPromotions")
                             || Column("isStarred") == true
                             || keepIds.contains(Column("id")))
            case "CATEGORY_SOCIAL":
                q = q.filter(tabClear("inSocial")
                             || Column("isStarred") == true
                             || keepIds.contains(Column("id")))
            default:
                q = q.filter(!Column("labelIds").like("%\(cat)%")
                             || Column("isStarred") == true
                             || keepIds.contains(Column("id")))
            }
        }
        return q
    }

    /// Keep the threads that contain any of the `show` categories. Denorm for
    /// promo/social; labelIds LIKE for Updates/Forums (no denorm columns yet).
    /// Spam is never a category tab: SPAM stays out of promo/social picks.
    ///
    /// Accounts in `exemptAccounts` (the setting "Show Promotions and Social"
    /// is off) ignore Promotions and Social in the pick, exactly as their own
    /// scope does: the pick minus those two applies to them, and when nothing
    /// is left it does not narrow them at all.
    static func applyShow(
        _ query: QueryInterfaceRequest<MailThread>,
        show: Set<String>,
        exemptAccounts: Set<String> = []
    ) -> QueryInterfaceRequest<MailThread> {
        guard !show.isEmpty else { return query }
        var q = query
        let offList = CategoryRows.sqlList(exemptAccounts)
        let hasExempt = !offList.isEmpty && !show.isDisjoint(with: CategoryRows.categories)
        let onlyTabs = show.isSubset(of: CategoryRows.categories)
        let notExempt = "accountId NOT IN (\(offList))"
        let exemptSQL = "accountId IN (\(offList))"
        var parts: [String] = []
        var args: [any DatabaseValueConvertible] = []
        var needsNotSpam = false
        for cat in show {
            switch cat {
            case "CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL":
                let flag = cat == "CATEGORY_PROMOTIONS" ? "inPromotions" : "inSocial"
                // With other categories in the pick, an exempt account keeps
                // only those: the two tabs match for the other accounts.
                parts.append(hasExempt && !onlyTabs
                             ? "(\(flag) = 1 AND \(notExempt))" : "\(flag) = 1")
                needsNotSpam = true
            default:
                parts.append("labelIds LIKE ?")
                args.append("%\(cat)%")
            }
        }
        // A pick of the two tabs alone does not narrow an exempt account.
        let whole = hasExempt && onlyTabs
        q = q.filter(sql: (parts.joined(separator: " OR ")) + (whole ? " OR \(exemptSQL)" : ""),
                     arguments: StatementArguments(args))
        if needsNotSpam {
            q = hasExempt
                ? q.filter(sql: "inSpam = 0 OR \(exemptSQL)")
                : q.filter(Column("inSpam") == false)
        }
        return q
    }

    /// Legacy saved-view "Exclude Promotions & Social" structured field.
    /// Same starred / keepIds pin-through as `apply` for the promo+social pair.
    static func applyExcludePromotions(
        _ query: QueryInterfaceRequest<MailThread>,
        keepIds: [String] = []
    ) -> QueryInterfaceRequest<MailThread> {
        query.filter((Column("inPromotions") == false && Column("inSocial") == false)
                     || Column("isStarred") == true
                     || keepIds.contains(Column("id")))
    }
}
