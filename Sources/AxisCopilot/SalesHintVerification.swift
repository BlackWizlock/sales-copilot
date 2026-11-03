import Foundation
import CopilotCore

/// Explicit opt-in paid synthetic inference check; never records or reads client meetings.
@MainActor enum SalesHintVerification {
    static func run() async throws {
        guard ProcessInfo.processInfo.environment["AXIS_COPILOT_ALLOW_PAID_SYNTHETIC_TEST"] == "1" else {
            throw CopilotError.message("Paid synthetic workflow is opt-in; no model request was sent")
        }
        let intelligence = LocalIntelligence()
        try intelligence.record.addMaterials([
            SupportMaterial(name: "scope.txt", text: "Обучение команды входит в объём работ."),
            SupportMaterial(name: "terms.txt", text: "Стоимость сопровождения составляет 100 рублей в месяц. Оплата после подписания акта.")
        ])
        var session = MeetingSession(title: "Synthetic sales hint verification")
        session.transcript = [TranscriptLine(source: .meeting, start: 0, end: 4, text: "Сколько стоит сопровождение в месяц?")]
        intelligence.observe(session, directory: nil)
        // A later local microphone chunk must not replace the client's question or cancel generation.
        session.transcript.append(TranscriptLine(source: .microphone, start: 4, end: 5, text: "Сейчас посмотрю условия."))
        intelligence.observe(session, directory: nil)
        let deadline = Date().addingTimeInterval(150)
        while intelligence.busySuggestion && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard !intelligence.busySuggestion, intelligence.suggestionError.isEmpty,
              intelligence.clientUtterance == "Сколько стоит сопровождение в месяц?",
              intelligence.suggestion.contains("100"), intelligence.suggestion.contains("после подписания акта"),
              intelligence.suggestionEvidence.contains("terms.txt") else {
            throw CopilotError.message("Synthetic automatic sales hint failed: \(intelligence.suggestionError)")
        }
        print("PASS: automatic local sales hint, multiple source documents, named citation and microphone isolation")
    }
}
