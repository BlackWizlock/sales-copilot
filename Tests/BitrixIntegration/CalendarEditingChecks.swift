import Foundation
import CopilotCore

actor CalendarEditFixture: BitrixTransport {
    var event: [String: CRMValue]
    var writes: [[String: CRMValue]] = []
    var failWrite = false
    init(recurring: Bool = false) {
        event = ["ID": .string("42"), "NAME": .string("Synthetic review"), "OWNER_ID": .string("7"), "DATE_FROM": .string("03.11.2026 00:30:00"), "DATE_TO": .string("03.11.2026 01:30:00"), "TZ_FROM": .string("Asia/Tokyo"), "DESCRIPTION": .string("Original"), "TIMESTAMP_X_ISO": .string("2026-11-01T12:00:00Z")]
        if recurring { event["RRULE"] = .object(["FREQ": .string("WEEKLY")]) }
    }
    func change() { event["DESCRIPTION"] = .string("Someone else's correction") }
    func fail() { failWrite = true }
    func snapshot() throws -> CalendarMeeting { try CalendarMeeting.decode(event) }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let params = try JSONDecoder().decode([String: CRMValue].self, from: request.httpBody!)
        let result: CRMValue
        switch request.url!.lastPathComponent {
        case "calendar.event.getbyid.json": result = .object(event)
        case "calendar.event.update.json":
            writes.append(params)
            if failWrite { throw URLError(.timedOut) }
            event["DESCRIPTION"] = params["description"]; result = .bool(true)
        case "calendar.event.get.json": result = .array([.object(event)])
        case "crm.deal.get.json": result = .object(["ID": .string("42"), "TITLE": .string("Consulting engagement"), "COMPANY_ID": .string("99")])
        case "crm.company.get.json": result = .object(["TITLE": .string("Synthetic client")])
        default: preconditionFailure("Unexpected request")
        }
        return (try JSONEncoder().encode(["result": result]), 200)
    }
}
@main struct CalendarEditingChecks {
    @MainActor static func main() async throws {
        func client(_ fixture: CalendarEditFixture) throws -> BitrixClient {
            BitrixClient(credentials: try BitrixCredentials(webhook: "https://synthetic.bitrix24.com/rest/7/fixture/"), transport: fixture)
        }
        let fixture = CalendarEditFixture(); let api = try client(fixture)
        let original = try await fixture.snapshot()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = CRMController(store: try SessionStore(root: root), client: api, ownerID: "7")
        await controller.refreshCalendar(from: original.starts, to: original.starts.addingTimeInterval(3600))
        try await controller.saveCalendarDescription(original, description: "[b]Agreed scope[/b]\n• First step")
        precondition(controller.meetings.first?.raw["DESCRIPTION"]?.text == "[b]Agreed scope[/b]\n• First step")
        let writes = await fixture.writes
        precondition(writes.count == 1 && Set(writes[0].keys) == ["id", "type", "ownerId", "description"])
        let details = try await api.calendarDeal("42")
        precondition(details.title == "Consulting engagement" && details.client == "Synthetic client")
        precondition(details.url.absoluteString == "https://synthetic.bitrix24.com/crm/deal/details/42/")
        let conflict = CalendarEditFixture(); let conflictEvent = try await conflict.snapshot(); await conflict.change()
        do { try await client(conflict).updateCalendarDescription(conflictEvent, description: "Overwrite", ownerID: "7"); preconditionFailure("Conflict accepted") } catch {}
        let conflictWrites = await conflict.writes; precondition(conflictWrites.isEmpty)
        let recurring = CalendarEditFixture(recurring: true); let occurrence = try await recurring.snapshot()
        try await client(recurring).updateCalendarDescription(occurrence, description: "Only this occurrence", ownerID: "7")
        let repeatWrites = await recurring.writes
        precondition(repeatWrites[0]["recurrence_mode"]?.text == "this" && repeatWrites[0]["current_date_from"]?.text == "2026-11-03")
        let timeout = CalendarEditFixture(); let timeoutEvent = try await timeout.snapshot(); await timeout.fail()
        do { try await client(timeout).updateCalendarDescription(timeoutEvent, description: "Uncertain", ownerID: "7"); preconditionFailure("Timeout accepted") } catch {}
        let timeoutWrites = await timeout.writes; precondition(timeoutWrites.count == 1)
        print("PASS: calendar description read-back, exact write scope, conflict refusal, occurrence-only timezone, no retry after timeout, deal title and client")
    }
}
