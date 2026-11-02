import Foundation
import CopilotCore

final class CalendarGridTests {
    func run() throws {
        try recurringOccurrencesUseExpandedDates()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!; calendar.firstWeekday = 2
        let march = BitrixDate.parse("2026-03-15T12:00:00+01:00")!
        let grid = try CalendarMonthGrid(displaying: march, calendar: calendar)
        precondition(grid.days.count == 42)
        precondition(calendar.component(.weekday, from: grid.days[0]) == 2)
        precondition(calendar.component(.month, from: grid.days[0]) == 2)
        precondition(grid.weekdays.first == 2)
        let transition = BitrixDate.parse("2026-03-29T12:00:00+02:00")!
        let day = try grid.interval(for: transition)
        precondition(day.duration == 23 * 3600)
        let event = try CalendarMeeting.decode(["ID": .string("1"), "NAME": .string("Multi day"), "DATE_FROM": .string("2026-03-28T23:30:00+01:00"), "DATE_TO": .string("2026-03-30T00:00:00+02:00")])
        let includesTransition = try grid.contains(event, on: transition)
        precondition(includesTransition)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: transition)!
        let includesNext = try grid.contains(event, on: nextDay)
        precondition(!includesNext)
        precondition(grid.range.start == grid.days.first && grid.range.end > grid.days.last!)
        print("PASS: calendar month padding, Monday-first order, DST and exclusive multi-day boundaries")
    }

    private func recurringOccurrencesUseExpandedDates() throws {
        // calendar.event.get expands civil dates, but leaves UTC timestamps at series bounds.
        let fields: [String: CRMValue] = [
            "ID": .string("100"), "DATE_FROM": .string("05.11.2026 11:00:00"),
            "DATE_TO": .string("05.11.2026 11:30:00"),
            "DATE_FROM_TS_UTC": .string("1783573200"), "DATE_TO_TS_UTC": .string("2145992400"),
            "TZ_FROM": .string("Europe/Moscow"), "TZ_TO": .string("Europe/Moscow"),
            "RRULE": .object(["FREQ": .string("WEEKLY")])
        ]
        let event = try CalendarMeeting.decode(fields)
        precondition(event.starts == BitrixDate.parse("2026-11-05T08:00:00Z"), "Recurring occurrence must use its expanded start, not the series start")
        precondition(event.ends == BitrixDate.parse("2026-11-05T08:30:00Z"), "Recurring occurrence must end after 30 minutes, not in 2038")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let grid = try CalendarMonthGrid(displaying: event.starts, calendar: calendar)
        let occupiedDays = try grid.days.filter { try grid.contains(event, on: $0) }
        precondition(occupiedDays.count == 1, "One weekly occurrence must not fill the month")
        let normal = try CalendarMeeting.decode(fields.merging(["RRULE": .string("")]) { _, new in new })
        precondition(normal.starts == event.starts, "Civil event dates and their declared zone also determine normal event time")
        let next = try CalendarMeeting.decode(fields.merging([
            "DATE_FROM": .string("12.11.2026 11:00:00"), "DATE_TO": .string("12.11.2026 11:30:00")
        ]) { _, new in new })
        precondition(next.id == event.id && next.occurrenceID != event.occurrenceID, "Recurring instances must retain their CRM ID and have distinct view identities")
        let reloaded = try CalendarMeeting.decode(fields)
        precondition(reloaded.occurrenceID == event.occurrenceID, "Reloading an occurrence must preserve its view identity")
        let fallback = try CalendarMeeting.decode([
            "ID": .string("101"), "DATE_FROM": .string("06.11.2026 00:00:00"), "TZ_FROM": .string(""),
            "DATE_FROM_TS_UTC": .string("1793912400"), "DATE_TO_TS_UTC": .string("1793998800"), "DT_SKIP_TIME": .string("Y")
        ])
        precondition(fallback.starts == Date(timeIntervalSince1970: 1793912400) && fallback.ends == Date(timeIntervalSince1970: 1793998800), "Zone-free all-day records must retain timestamp fallback")
        print("PASS: expanded recurring dates override stale series timestamps")
    }
}
#if CALENDAR_STANDALONE
@main struct CalendarMain { static func main() throws { try CalendarGridTests().run() } }
#endif
