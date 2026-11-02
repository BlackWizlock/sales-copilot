import Foundation
import CopilotCore

struct MeetingChatTests {
    func run() throws {
        let draft = StructuredMeetingSummary(overview: "Обсудили аудит.", decisions: ["Начать аудит"], actions: [.init(task: "Прислать список", owner: "Анна", deadline: "пятница")], questions: ["Цена не согласована"], citations: [])
        precondition(draft.markdown.contains("## Итог") && draft.markdown.contains("## Следующие шаги"))
        precondition(draft.markdown.contains("Анна") && draft.markdown.contains("пятница"))
        var session = MeetingSession(title: "Synthetic chat")
        session.state = .completed
        session.transcript = (0..<1600).map { TranscriptLine(source: .meeting, start: Double($0), end: Double($0 + 1), text: "Обсуждаем порядок сортировки материалов.") }
        let final = TranscriptLine(source: .meeting, start: 1700, end: 1708, text: "Анна пришлет список сотрудников в пятницу.")
        session.transcript.append(final)
        let context = MeetingQuestionContext(session: session, question: "Кто пришлет список сотрудников?", recentQuestions: [])
        precondition(context.selectedLines.contains { $0.id == final.id })
        precondition(context.prompt.count < 20_000)
        let citation = SummaryCitation(segmentID: final.id, seconds: final.start, quote: "Анна пришлет список сотрудников в пятницу.")
        precondition(context.validated(citations: [citation]).count == 1)
        precondition(context.validated(citations: [SummaryCitation(segmentID: UUID(), seconds: 1700, quote: "Анна")]).isEmpty)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var archive = MeetingChatArchive(meetingID: session.id)
        archive.messages = [MeetingChatMessage(role: .answer, text: "Ответ", citations: [citation], fingerprint: "synthetic", model: "synthetic")]
        try archive.save(directory: root)
        try archive.save(directory: root)
        let loaded = try MeetingChatArchive.load(directory: root, meetingID: session.id)
        precondition(loaded.messages.count == 1 && loaded.messages[0].citations[0].seconds == 1700)
        do { _ = try MeetingChatArchive.load(directory: root, meetingID: UUID()); preconditionFailure("Wrong meeting must fail") } catch {}
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("chat.json").path)[.posixPermissions] as? Int
        precondition(mode == 0o600)
        print("PASS: structured summary, full-transcript tail retrieval, chat citations, isolation and private atomic chat archive")
    }
}
