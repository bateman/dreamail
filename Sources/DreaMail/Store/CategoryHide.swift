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
        // Promotions and Social are never hidden for these accounts
        // (`CategoryRows`: the setting is off).
        let exempt = !exemptAccounts.isEmpty
            ? exemptAccounts.contains(Column("accountId")) : Column("id") != Column("id")
        for cat in hide {
            switch cat {
            case "CATEGORY_PROMOTIONS":
                q = q.filter(Column("inPromotions") == false
                             || exempt
                             || Column("isStarred") == true
                             || keepIds.contains(Column("id")))
            case "CATEGORY_SOCIAL":
                q = q.filter(Column("inSocial") == false
                             || exempt
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
    /// Accounts in `exemptAccounts` (the setting "Show Promotions and Social"
    /// is off) are not narrowed by a pick of those two.
    static func applyShow(
        _ query: QueryInterfaceRequest<MailThread>,
        show: Set<String>,
        exemptAccounts: Set<String> = []
    ) -> QueryInterfaceRequest<MailThread> {
        guard !show.isEmpty else { return query }
        var q = query
        var parts: [String] = []
        var args: [any DatabaseValueConvertible] = []
        var needsNotSpam = false
        for cat in show {
            switch cat {
            case "CATEGORY_PROMOTIONS":
                parts.append("inPromotions = 1")
                needsNotSpam = true
            case "CATEGORY_SOCIAL":
                parts.append("inSocial = 1")
                needsNotSpam = true
            default:
                parts.append("labelIds LIKE ?")
                args.append("%\(cat)%")
            }
        }
        let offList = show.isDisjoint(with: CategoryRows.categories)
            ? "" : CategoryRows.sqlList(exemptAccounts)
        let exemptSQL = offList.isEmpty ? "" : "accountId IN (\(offList))"
        q = q.filter(sql: ([parts.joined(separator: " OR ")]
                            + (exemptSQL.isEmpty ? [] : [exemptSQL])).joined(separator: " OR "),
                     arguments: StatementArguments(args))
        if needsNotSpam {
            q = exemptSQL.isEmpty
                ? q.filter(Column("inSpam") == false)
                : q.filter(sql: "inSpam = 0 OR \(exemptSQL)")
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
