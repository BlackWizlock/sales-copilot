import Foundation

/// Calendar arithmetic deliberately uses civil days, including DST transitions.
public struct CalendarMonthGrid: Sendable {
    public let calendar: Calendar
    public let monthStart: Date
    public let days: [Date]
    public let weekdays: [Int]
    public let range: DateInterval

    public init(displaying date: Date, calendar: Calendar = .current) throws {
        guard let month = calendar.dateInterval(of: .month, for: date),
              let last = calendar.date(byAdding: .day, value: -1, to: month.end) else {
            throw CopilotError.message("Не удалось построить календарь")
        }
        self.calendar = calendar; monthStart = month.start
        weekdays = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        let padding = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -padding, to: month.start) else { throw CopilotError.message("Не удалось построить календарь") }
        let count = padding + calendar.component(.day, from: last)
        let paddedCount = ((count + 6) / 7) * 7
        days = (0..<paddedCount).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        guard days.count == paddedCount, let end = calendar.date(byAdding: .day, value: paddedCount, to: start) else { throw CopilotError.message("Не удалось построить календарь") }
        range = DateInterval(start: start, end: end)
    }
    public func interval(for day: Date) throws -> DateInterval {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { throw CopilotError.message("Не удалось определить день") }
        return interval
    }
    public func contains(_ event: CalendarMeeting, on day: Date) throws -> Bool {
        let interval = try interval(for: day)
        if let end = event.ends, end > event.starts { return event.starts < interval.end && end > interval.start }
        return event.starts >= interval.start && event.starts < interval.end
    }
}
