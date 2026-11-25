import XCTest

final class LabelPickerKeyRulesTests: XCTestCase {
    func testReturnClosesInLabelModeAndSpaceDoesNot() {
        XCTAssertTrue(LabelPickerKeyRules.closesAfterApply(moveMode: false, closeKey: true))
        XCTAssertFalse(LabelPickerKeyRules.closesAfterApply(moveMode: false, closeKey: false))
    }

    func testMoveModeCloseIsLeftToTheMove() {
        XCTAssertFalse(LabelPickerKeyRules.closesAfterApply(moveMode: true, closeKey: true))
    }

    func testFooterNamesWhatTheKeysDo() {
        XCTAssertEqual(LabelPickerKeyRules.footerHints(moveMode: false, onCreateRow: false),
                       ["↑↓ select", "↵ apply and close", "space toggle", "esc close"])
        XCTAssertEqual(LabelPickerKeyRules.footerHints(moveMode: false, onCreateRow: true),
                       ["↑↓ select", "↵ create", "esc close"])
        XCTAssertEqual(LabelPickerKeyRules.footerHints(moveMode: true, onCreateRow: false),
                       ["↑↓ select", "↵ move", "esc close"])
    }
}
