import XCTest
@testable import MishMail

final class ThreadRowActionsTests: XCTestCase {
    func testHoverActionsAreTheFourGmailOnesInOrder() {
        for unread in [true, false] {
            XCTAssertEqual(ThreadRowHoverAction.actions(isUnread: unread),
                           [.archive, .trash, .toggleRead, .snooze])
        }
    }

    func testThirdActionFlipsBetweenUnreadAndRead() {
        XCTAssertEqual(ThreadRowHoverAction.toggleRead.title(isUnread: false), "Mark as unread")
        XCTAssertEqual(ThreadRowHoverAction.toggleRead.symbol(isUnread: false), "envelope.badge")
        XCTAssertEqual(ThreadRowHoverAction.toggleRead.title(isUnread: true), "Mark as read")
        XCTAssertEqual(ThreadRowHoverAction.toggleRead.symbol(isUnread: true), "envelope.open")
    }

    func testOtherActionsDoNotDependOnReadState() {
        for action in [ThreadRowHoverAction.archive, .trash, .snooze] {
            XCTAssertEqual(action.title(isUnread: true), action.title(isUnread: false))
            XCTAssertEqual(action.symbol(isUnread: true), action.symbol(isUnread: false))
        }
        XCTAssertEqual(ThreadRowHoverAction.archive.symbol(isUnread: false), "archivebox")
        XCTAssertEqual(ThreadRowHoverAction.trash.symbol(isUnread: false), "trash")
        XCTAssertEqual(ThreadRowHoverAction.snooze.symbol(isUnread: false), "clock")
    }

    func testEveryActionHasAUniqueIdentifier() {
        let ids = ThreadRowHoverAction.allCases.map(\.identifier)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testSlotFitsTheButtonsAtEveryFontScale() {
        for scale in [0.8, 1.0, 1.25, 1.5, 2.0] {
            let slot = ThreadRowActionLayout.slotWidth(fontScale: scale)
            XCTAssertGreaterThanOrEqual(slot, ThreadRowActionLayout.actionsWidth(fontScale: scale))
            XCTAssertGreaterThanOrEqual(slot, ThreadRowActionLayout.dateMinWidth)
        }
    }

    func testSlotGrowsWithFontScaleOnceButtonsOutweighTheDate() {
        let small = ThreadRowActionLayout.slotWidth(fontScale: 1.0)
        let large = ThreadRowActionLayout.slotWidth(fontScale: 2.0)
        XCTAssertGreaterThan(large, small)
        // Four 19 pt buttons and three 2 pt gaps at scale 1.
        XCTAssertEqual(ThreadRowActionLayout.actionsWidth(fontScale: 1.0), 82, accuracy: 0.001)
    }
}
