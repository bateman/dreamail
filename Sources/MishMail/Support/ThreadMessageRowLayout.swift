import Foundation
import CoreGraphics

/// Geometry of one message row in the reading pane's conversation view
/// (Gmail on the web): a flat, full-width row with a 40 pt avatar, the
/// sender in bold with the date on the right, and one secondary line below
/// (the snippet when collapsed, the recipients when open). Rows are split by
/// a hairline, not by card spacing. Every length scales with the reading
/// pane's font scale.
struct ThreadMessageRowMetrics: Equatable {
    let fontScale: Double

    init(fontScale: Double) {
        // A corrupt preference must not collapse or explode the row.
        self.fontScale = min(max(fontScale, 0.5), 2.5)
    }

    private var s: CGFloat { CGFloat(fontScale) }

    var avatarSize: CGFloat { 40 * s }
    /// From the pane's leading edge to the avatar.
    var leadingInset: CGFloat { 16 * s }
    /// Between the avatar and the text column.
    var avatarGap: CGFloat { 16 * s }
    var trailingInset: CGFloat { 16 * s }
    /// Above and below the header (avatar and its two text lines). With the
    /// 40 pt avatar this makes a collapsed row 80 pt tall at the default size.
    var verticalPadding: CGFloat { 20 * s }
    /// Between the name line and the line below it.
    var lineSpacing: CGFloat { 4 * s }
    var nameFontSize: CGFloat { 14 * s }
    var dateFontSize: CGFloat { 12 * s }
    var secondaryFontSize: CGFloat { 13 * s }
    /// Horizontal inset of an open message's body, attachments and action
    /// bar: the 16 pt pane margin plus the 16 pt the card used to add, so the
    /// body keeps the reading width it had. Not scaled, as before.
    var bodyInset: CGFloat { 32 }

    /// The collapsed row's height: the avatar between the two paddings (the
    /// two text lines are shorter than the avatar).
    var collapsedRowHeight: CGFloat { avatarSize + 2 * verticalPadding }

    /// Where the name, the snippet and the recipients start.
    var textColumnLeading: CGFloat { leadingInset + avatarSize + avatarGap }

    /// Width of the text column in a row `rowWidth` wide.
    func textColumnWidth(rowWidth: CGFloat) -> CGFloat {
        max(0, rowWidth - textColumnLeading - trailingInset)
    }
}

/// How much of the date the name line shows. The date shares the line with
/// the sender's name, so on a narrow pane it gives up its relative part, then
/// shrinks to the thread list's compact form, before the name is squeezed.
/// The snippet line is never shortened by the date: it runs the full text
/// column width below it.
enum MessageRowDateStyle: Equatable {
    /// "Nov 23, 5:28 PM (1 day ago)".
    case absoluteWithRelative
    /// "Nov 23, 5:28 PM".
    case absolute
    /// "5:28 PM" today, "Nov 23" otherwise.
    case compact

    /// Text column width the full date needs, with room for a sender name.
    static let fullWidth: CGFloat = 400
    /// Text column width the absolute date needs, with room for a name.
    static let absoluteWidth: CGFloat = 270

    /// The style for a text column `textColumnWidth` wide at `fontScale`
    /// (the date and the name grow with the font scale, so do the widths).
    static func forTextColumn(width textColumnWidth: CGFloat,
                              fontScale: Double) -> MessageRowDateStyle {
        let s = CGFloat(ThreadMessageRowMetrics(fontScale: fontScale).fontScale)
        if textColumnWidth >= fullWidth * s { return .absoluteWithRelative }
        if textColumnWidth >= absoluteWidth * s { return .absolute }
        return .compact
    }
}

enum MessageRowDate {
    /// The date as the name line shows it in `style`. Uses the app's date
    /// helpers (`messageHeaderFormat`, `threadListFormat`); the relative part
    /// is "(12 hours ago)" style, and a date in the future (clock skew)
    /// reads as "now" rather than "in 2 minutes".
    static func text(_ date: Date, style: MessageRowDateStyle,
                     now: Date = Date()) -> String {
        switch style {
        case .compact:
            return date.formatted(date.threadListFormat)
        case .absolute:
            return date.formatted(date.messageHeaderFormat)
        case .absoluteWithRelative:
            let absolute = date.formatted(date.messageHeaderFormat)
            return "\(absolute) (\(relative(date, now: now)))"
        }
    }

    /// "12 hours ago", "1 day ago"; "now" under a minute or in the future.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        if now.timeIntervalSince(date) < 60 {
            formatter.dateTimeStyle = .named
            return formatter.localizedString(fromTimeInterval: 0)
        }
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Which avatar a message row shows. Mail sent from one of the user's own
/// accounts (or one of its send-as aliases) shows that account's avatar:
/// its stored Google photo when there is one, else its initial disc in the
/// account's colour. Everyone else gets an initial disc in a stable colour
/// keyed by their address. No photo is ever fetched for other senders.
enum MessageAvatar: Equatable {
    /// The stored profile photo of this account.
    case accountPhoto(accountId: String)
    /// An initial disc: `name`'s first letter on `Color.stable(for: key)`.
    case initial(name: String, key: String)

    /// - Parameters:
    ///   - senderEmail: the From address.
    ///   - senderName: the display name shown in the row.
    ///   - messageAccountId: the mailbox the message belongs to.
    ///   - accountIds: every signed-in account (their ids are addresses).
    ///   - ownAddresses: accounts and their send-as aliases.
    ///   - accountsWithPhoto: accounts that have a stored photo.
    static func resolve(senderEmail: String, senderName: String,
                        messageAccountId: String, accountIds: [String],
                        ownAddresses: Set<String>,
                        accountsWithPhoto: Set<String>) -> MessageAvatar {
        let email = senderEmail.trimmingCharacters(in: .whitespaces).lowercased()
        let name = senderName.trimmingCharacters(in: .whitespaces)
        let shownName = name.isEmpty ? email : name
        let ownAccount: String? = {
            if let exact = accountIds.first(where: { $0.lowercased() == email }) {
                return exact
            }
            // A send-as alias belongs to the mailbox that holds the message.
            let isAlias = ownAddresses.contains { $0.lowercased() == email }
            return isAlias && !email.isEmpty ? messageAccountId : nil
        }()
        if let ownAccount {
            if accountsWithPhoto.contains(ownAccount) {
                return .accountPhoto(accountId: ownAccount)
            }
            return .initial(name: shownName, key: ownAccount)
        }
        return .initial(name: shownName, key: email.isEmpty ? shownName : email)
    }
}
