import CompletionCore
import Foundation
import XCTest

final class DailyAcceptanceCounterTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testKeepsCountingAcrossRelaunchesOnTheSameDay() {
        let morning = Date(timeIntervalSince1970: 1_774_508_400)
        let afternoon = morning.addingTimeInterval(6 * 60 * 60)
        var counter = DailyAcceptanceCounter(
            count: 7,
            referenceDate: morning,
            calendar: calendar
        )

        XCTAssertFalse(counter.refresh(for: afternoon))
        XCTAssertEqual(counter.recordAcceptance(at: afternoon), 8)
    }

    func testResetsWhenTheCalendarDayChanges() {
        let firstDay = Date(timeIntervalSince1970: 1_774_508_400)
        let nextDay = firstDay.addingTimeInterval(24 * 60 * 60)
        var counter = DailyAcceptanceCounter(
            count: 7,
            referenceDate: firstDay,
            calendar: calendar
        )

        XCTAssertTrue(counter.refresh(for: nextDay))
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(counter.recordAcceptance(at: nextDay), 1)
    }
}
