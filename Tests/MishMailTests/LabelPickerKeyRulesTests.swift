import XCTest

final class LabelPickerKeyRulesTests: XCTestCase {
    func testReturnClosesInLabelModeAndSpaceDoesNot() {
        XCTAssertTrue(LabelPickerKeyRules.closesAfterApply(mode: .label, closeKey: true))
        XCTAssertFalse(LabelPickerKeyRules.closesAfterApply(mode: .label, closeKey: false))
    }

    func testMoveModeCloseIsLeftToTheMove() {
        XCTAssertFalse(LabelPickerKeyRules.closesAfterApply(mode: .move, closeKey: true))
    }

    func testFooterNamesWhatTheKeysDo() {
        XCTAssertEqual(LabelPickerKeyRules.footerHints(mode: .label, onCreateRow: false),
                       ["↑↓ select", "↵ apply and close", "space toggle", "esc close"])
        XCTAssertEqual(LabelPickerKeyRules.footerHints(mode: .label, onCreateRow: true),
                       ["↑↓ select", "↵ create", "esc close"])
        XCTAssertEqual(LabelPickerKeyRules.footerHints(mode: .move, onCreateRow: false),
                       ["↑↓ select", "↵ move", "esc close"])
    }
}
