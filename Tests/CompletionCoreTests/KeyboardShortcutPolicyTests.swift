import CompletionCore
import XCTest

final class KeyboardShortcutPolicyTests: XCTestCase {
    func testTabModifiersChooseWordWholeSuggestionOrPassThrough() {
        XCTAssertEqual(
            KeyboardShortcutPolicy.tabAction(
                command: false,
                shift: false,
                control: false,
                option: false
            ),
            .acceptNextWord
        )
        XCTAssertEqual(
            KeyboardShortcutPolicy.tabAction(
                command: false,
                shift: false,
                control: false,
                option: true
            ),
            .acceptEntireSuggestion
        )

        for modifiers in [
            (command: true, shift: false, control: false, option: false),
            (command: false, shift: true, control: false, option: false),
            (command: false, shift: false, control: true, option: false),
            (command: false, shift: true, control: false, option: true),
        ] {
            XCTAssertEqual(
                KeyboardShortcutPolicy.tabAction(
                    command: modifiers.command,
                    shift: modifiers.shift,
                    control: modifiers.control,
                    option: modifiers.option
                ),
                .passThrough
            )
        }
    }

    func testStandardScreenshotShortcutsPreserveSuggestion() {
        for keyCode in [20, 21, 22, 23] as [Int64] {
            XCTAssertTrue(
                KeyboardShortcutPolicy.preservesSuggestion(
                    keyCode: keyCode,
                    command: true,
                    shift: true,
                    control: false,
                    option: false
                )
            )
        }
    }

    func testClipboardScreenshotVariantsPreserveSuggestion() {
        XCTAssertTrue(
            KeyboardShortcutPolicy.preservesSuggestion(
                keyCode: 21,
                command: true,
                shift: true,
                control: true,
                option: false
            )
        )
    }

    func testSelectionScreenshotBeginsPointerPreservation() {
        XCTAssertTrue(
            KeyboardShortcutPolicy.beginsInteractiveScreenshot(
                keyCode: 21,
                command: true,
                shift: true,
                control: false,
                option: false
            )
        )
        XCTAssertFalse(
            KeyboardShortcutPolicy.beginsInteractiveScreenshot(
                keyCode: 20,
                command: true,
                shift: true,
                control: false,
                option: false
            )
        )
    }

    func testEditorAffectingAndLookalikeShortcutsInvalidate() {
        XCTAssertFalse(
            KeyboardShortcutPolicy.preservesSuggestion(
                keyCode: 9,
                command: true,
                shift: false,
                control: false,
                option: false
            )
        )
        XCTAssertFalse(
            KeyboardShortcutPolicy.preservesSuggestion(
                keyCode: 21,
                command: true,
                shift: false,
                control: false,
                option: false
            )
        )
        XCTAssertFalse(
            KeyboardShortcutPolicy.preservesSuggestion(
                keyCode: 21,
                command: true,
                shift: true,
                control: false,
                option: true
            )
        )
    }
}
