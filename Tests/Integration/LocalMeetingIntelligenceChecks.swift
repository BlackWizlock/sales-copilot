import Foundation

/// Standalone executable integration check. Synthetic content only; fixed local Ollama.
@main struct LocalMeetingIntelligenceChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axis-synthetic-meeting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var session = MeetingSession(title: "Synthetic meeting")
        session.state = .completed
        session.transcript = [
            TranscriptLine(source: .meeting, start: 2, end: 5, text: "Договорились провести аудит процессов."),
            TranscriptLine(source: .microphone, start: 8, end: 13, text: "Анна пришлет список сотрудников в пятницу."),
            TranscriptLine(source: .meeting, start: 15, end: 20, text: "Стоимость аудита пока не согласована.")
        ]
        let intelligence = LocalIntelligence()
        let started = Date()
        intelligence.observe(session, directory: root)
        for _ in 0..<1200 {
            if !intelligence.busySummary { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(!intelligence.busySummary && intelligence.error.isEmpty, intelligence.error)
        precondition(intelligence.summaryText.contains("## Следующие шаги") && intelligence.summaryText.contains("Анна"))
        precondition(intelligence.record.summary?.citations.allSatisfy { $0.isValid(in: session.transcript) } == true)
        print("PASS: actual local structured summary persisted; seconds \(Date().timeIntervalSince(started))")
        let chat = intelligence.chat
        chat.input = "Кто пришлет список сотрудников и когда?"
        let asked = Date(); chat.ask()
        for _ in 0..<1200 {
            if !chat.busy { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(!chat.busy && chat.error.isEmpty, chat.error)
        guard let answer = chat.messages.last else { preconditionFailure("No answer") }
        precondition(answer.state == .completed && answer.text.contains("Анна") && !answer.citations.isEmpty)
        precondition(answer.citations.allSatisfy { $0.isValid(in: session.transcript) })
        let restored = try MeetingChatArchive.load(directory: root, meetingID: session.id)
        precondition(restored.messages.count == 2)
        print("PASS: actual local meeting question, exact timestamp citations and chat reload; seconds \(Date().timeIntervalSince(asked))")
        chat.input = "Кто пришлет список?"; chat.ask()
        var updated = session
        updated.transcript[0].text = "Текст уточнён после повторного распознавания."
        chat.observe(updated, directory: root)
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(!chat.busy && chat.messages.last?.state == .cancelled)
        let afterChange = try MeetingChatArchive.load(directory: root, meetingID: session.id)
        precondition(afterChange.messages.last?.state == .cancelled)
        print("PASS: transcript fingerprint change cancels and persists pending answer without stale completion")
        chat.input = "Кто пришлет список?"; chat.ask()
        let secondRoot = root.appendingPathComponent("second"); try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        var other = MeetingSession(title: "Synthetic other"); other.state = .interrupted
        intelligence.observe(other, directory: secondRoot)
        try await Task.sleep(nanoseconds: 700_000_000)
        precondition(chat.messages.isEmpty && !chat.busy)
        let previous = try MeetingChatArchive.load(directory: root, meetingID: session.id)
        precondition(previous.messages.last?.state == .cancelled)
        precondition(!FileManager.default.fileExists(atPath: secondRoot.appendingPathComponent("chat.json").path))
        print("PASS: session switch cancels pending answer and cannot write into another meeting")
    }
}
