import AppKit
import SwiftUI
import CopilotCore

/// Explicit, synthetic-only native UI fixture. No Keychain or network transport.
@MainActor enum CalendarUIVerification {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CalendarUITransport()
        let credentials = try BitrixCredentials(webhook: "https://synthetic.bitrix24.com/rest/7/fixture/")
        let controller = CRMController(store: try SessionStore(root: root),
                                       client: BitrixClient(credentials: credentials, transport: transport), ownerID: "7")
        fixtureController = controller
        CalendarVerificationApp.main()
        fixtureController = nil
    }
}

@MainActor private var fixtureController: CRMController?

private struct CalendarVerificationApp: App {
    var body: some Scene {
        Window("Axis Copilot - Synthetic calendar", id: "synthetic-calendar") {
            if let controller = fixtureController {
                MeetingCalendarView(controller: controller, onSelectDeal: { _ in })
                    .onAppear {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                        Task {
                            try? await Task.sleep(for: .seconds(240))
                            NSApp.terminate(nil)
                        }
                    }
            }
        }.defaultSize(width: 960, height: 760)
    }
}

private actor CalendarUITransport: BitrixTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let start = Calendar.current.date(bySettingHour: 13, minute: 0, second: 0, of: Date())!
        let iso = ISO8601DateFormatter()
        let event: [String: CRMValue] = [
            "ID": .string("42"), "NAME": .string("Обсуждение проекта с тестовым клиентом"),
            "OWNER_ID": .string("7"), "DATE_FROM": .string(iso.string(from: start)),
            "DATE_TO": .string(iso.string(from: start.addingTimeInterval(3600))),
            "DESCRIPTION": .string("[b]Повестка встречи[/b]\n[list][*]Обсудить объём работ[*]Согласовать следующий шаг[/list]\nМатериалы: [url=https://example.com/offer]Предложение по проекту[/url]\nВидеовстреча: https://telemost.360.yandex.ru/j/1234567890"),
            "UF_CRM_CAL_EVENT": .array([.string("D_42")]), "LOCATION": .string("Видеовстреча")]
        let result: CRMValue
        switch request.url?.lastPathComponent {
        case "calendar.event.get.json": result = .array([.object(event)])
        case "calendar.event.getbyid.json": result = .object(event)
        case "crm.deal.get.json": result = .object(["ID": .string("42"), "TITLE": .string("Консалтинг по процессам"), "COMPANY_ID": .string("99")])
        case "crm.company.get.json": result = .object(["TITLE": .string("Тестовая компания")])
        default: throw CopilotError.message("Synthetic UI fixture rejects writes and unknown methods")
        }
        return (try JSONEncoder().encode(["result": result]), 200)
    }
}
