import CompletionCore
import XCTest

final class GeneralSettingsTests: XCTestCase {
    func testDefaultsPreserveCurrentAcceptanceBehavior() {
        let settings = GeneralSettings()

        XCTAssertTrue(settings.showMenuBarIcon)
        XCTAssertFalse(settings.includeTrailingSpaceWhenAcceptingWord)
        XCTAssertTrue(settings.includeTrailingPunctuationWhenAcceptingWord)
        XCTAssertEqual(
            settings.suggestionAcceptanceOptions,
            .init(
                includeTrailingSpace: false,
                includeTrailingPunctuation: true
            )
        )
    }

    func testSettingsRoundTripThroughCodable() throws {
        let settings = GeneralSettings(
            showMenuBarIcon: false,
            includeTrailingSpaceWhenAcceptingWord: true,
            includeTrailingPunctuationWhenAcceptingWord: false
        )

        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(
            try JSONDecoder().decode(GeneralSettings.self, from: data),
            settings
        )
    }
}
