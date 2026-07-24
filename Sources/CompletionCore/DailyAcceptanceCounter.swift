import Foundation

public struct DailyAcceptanceCounter: Sendable, Equatable {
    public private(set) var count: Int
    public private(set) var referenceDate: Date
    private let calendar: Calendar

    public init(
        count: Int,
        referenceDate: Date,
        calendar: Calendar = .current
    ) {
        self.count = max(0, count)
        self.referenceDate = referenceDate
        self.calendar = calendar
    }

    @discardableResult
    public mutating func refresh(for date: Date) -> Bool {
        guard !calendar.isDate(referenceDate, inSameDayAs: date) else {
            return false
        }

        count = 0
        referenceDate = date
        return true
    }

    @discardableResult
    public mutating func recordAcceptance(at date: Date) -> Int {
        refresh(for: date)
        count += 1
        referenceDate = date
        return count
    }
}
