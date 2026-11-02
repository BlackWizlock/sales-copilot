import Foundation
import CopilotCore

actor CalendarFixture: BitrixTransport {
    var parameters: [String: CRMValue] = [:]
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        precondition(request.url?.lastPathComponent == "calendar.event.get.json")
        parameters = try JSONDecoder().decode([String: CRMValue].self, from: request.httpBody!)
        let event: CRMValue = .object(["ID": .string("1"), "NAME": .string("Historical fixture"), "DATE_FROM": .string("2026-03-15T10:00:00Z"), "DATE_TO": .string("2026-03-15T11:00:00Z")])
        return (try JSONEncoder().encode(["result": CRMValue.array([event])]), 200)
    }
}

@main struct CalendarControllerChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let fixture = CalendarFixture()
        let client = BitrixClient(credentials: try BitrixCredentials(webhook: "https://synthetic.bitrix24.com/rest/1/fixture/"), transport: fixture)
        let controller = CRMController(store: store, client: client, ownerID: "42")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; calendar.firstWeekday = 2
        let grid = try CalendarMonthGrid(displaying: BitrixDate.parse("2026-03-15T10:00:00Z")!, calendar: calendar)
        await controller.refreshCalendar(from: grid.range.start, to: grid.range.end)
        precondition(controller.meetings.count == 1, "History must not be filtered as future-only")
        let parameters = await fixture.parameters
        precondition(parameters["ownerId"]?.text == "42")
        precondition(BitrixDate.parse(parameters["from"]!.text) == grid.range.start)
        precondition(BitrixDate.parse(parameters["to"]!.text) == grid.range.end)
        await controller.refreshCalendar()
        precondition(controller.meetings.isEmpty, "Default upcoming view retains future-only behavior")
        print("PASS: visible calendar range, historical events, user calendar and default upcoming behavior")
    }
}
