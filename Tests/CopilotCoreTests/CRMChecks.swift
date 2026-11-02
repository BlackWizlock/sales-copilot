import Foundation
import CopilotCore

final class CRMChecks {
    func run() throws {
        precondition(MeetingLink.validated("https://telemost.yandex.ru/j/123") != nil)
        precondition(MeetingLink.validated("https://telemost.360.yandex.ru/j/123") != nil, "Current Telemost links must be recognized")
        precondition(MeetingLink.validated("https://telemost.360.yandex.ru.evil.example/j/123") == nil)
        precondition(MeetingLink.validated("https://us02web.zoom.us/j/123?pwd=abc") != nil)
        precondition(MeetingLink.validated("https://zoom.us.evil.example/j/123") == nil)
        precondition(MeetingLink.validated("https://evil@zoom.us/j/123") == nil)
        precondition(MeetingLink.validated("http://zoom.us/j/123") == nil)
        precondition(BitrixDate.parse("04.11.2026 10:00:00", timezone: "Europe/Moscow") == BitrixDate.parse("2026-11-04T07:00:00Z"))
        let event = try CalendarMeeting.decode(["ID": .string("12"), "NAME": .string("Test"), "DATE_FROM": .string("04.11.2026 10:00:00"), "TZ_FROM": .string("Europe/Moscow"), "UF_CRM_CAL_EVENT": .array([.string("D_468")]), "DESCRIPTION": .string("https://telemost.yandex.ru/j/123")])
        precondition(event.dealIDs == ["468"] && event.joinURL != nil)
        let timestampEvent = try CalendarMeeting.decode(["ID": .string("13"), "DATE_FROM": .string("04.11.2026 10:00:00"), "TZ_FROM": .string(""), "DATE_FROM_TS_UTC": .string("1793775600")])
        precondition(timestampEvent.starts == Date(timeIntervalSince1970: 1793775600))
        let context = DealContext(portal: "axisconsult.bitrix24.ru", dealID: "468", title: "Synthetic", fields: ["UF_CRM_1765470175": .string("Need")])
        precondition(context.asPlainText.contains("Need"))
        var session = MeetingSession(title: "Synthetic")
        session.state = .completed
        session.transcript = [TranscriptLine(source: .meeting, start: 1, end: 2, text: "Agreed")]
        let preview = try CRMExportPreview(session: session, context: context, summary: "Summary", audioURL: nil)
        let matches = try preview.matches(session: session, summary: "Summary", audioURL: nil)
        precondition(matches)
        session.transcript[0].text = "Changed"
        let changed = try preview.matches(session: session, summary: "Summary", audioURL: nil)
        precondition(!changed)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try CRMJournal(root: root)
        try journal.bind(context, meetingID: session.id)
        let bound = try journal.context(meetingID: session.id)
        precondition(bound?.dealID == "468")
        var operation = CRMExport(preview: preview)
        operation.state = .sending
        try journal.save(operation)
        let recovered = try journal.operation(meetingID: session.id)
        precondition(recovered?.state == .needsReconciliation)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
        precondition(permissions == 0o700)
        print("PASS: CRM core contracts")
    }
}
#if CRM_STANDALONE
@main struct CRMMain { static func main() throws { try CRMChecks().run() } }
#endif
