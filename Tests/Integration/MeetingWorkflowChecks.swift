import Foundation
import CopilotCore

/// Real local inference with synthetic documents and dialogue. No credentials or CRM writes.
@main struct MeetingWorkflowChecks {
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<3000 {
            if !predicate() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CopilotError.message("FAIL: local workflow exceeded five minutes")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axis-workflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var live = MeetingSession(title: "Synthetic consulting workflow")
        live.state = .recording
        let intelligence = LocalIntelligence()
        intelligence.observe(live, directory: root)
        try intelligence.record.addMaterials([SupportMaterial(name: "Synthetic terms.txt", text: "Аудит процессов стоит 120000 рублей. Длительность аудита 10 рабочих дней после получения исходных данных. В аудит входят интервью и карта процессов. Результат: отчёт и план изменений. Оплата: аванс 50 процентов. Встречи проходят в Телемосте. Обучение оплачивается отдельно. В стоимость включены две рабочие встречи.")])
        intelligence.updateContext()
        let questions = ["Сколько стоит аудит?", "Какой срок аудита?", "Что входит в аудит?", "Какой результат получим?", "Какая предоплата?", "Можно ли проводить встречи в Телемосте?", "Обучение входит в стоимость?", "Сколько встреч включено?", "Какая максимальная скидка?", "Вы гарантируете рост прибыли на 300 процентов?"]
        var latencies: [Double] = []
        for (index, question) in questions.enumerated() {
            live.transcript.append(TranscriptLine(source: .meeting, start: Double(index * 5), end: Double(index * 5 + 4), text: question))
            let started = Date()
            intelligence.observe(live, directory: root)
            try await wait { intelligence.busySuggestion }
            guard intelligence.suggestionError.isEmpty, !intelligence.suggestion.isEmpty else {
                throw CopilotError.message("FAIL: automatic hint missing at case \(index); \(intelligence.suggestionError)")
            }
            guard !intelligence.suggestion.contains("300"), !intelligence.suggestion.contains("скидка 20") else {
                throw CopilotError.message("FAIL: fabricated numerical sales promise")
            }
            latencies.append(Date().timeIntervalSince(started))
            print("PASS: automatic synthetic objection \(index + 1), seconds \(latencies.last!)")
        }
        var completed = MeetingSession(title: "Synthetic faithful summary")
        completed.state = .completed
        completed.transcript = [
            TranscriptLine(source: .meeting, start: 0, end: 4, text: "Хотелось бы обсудить скидку. Пока ничего не согласовано."),
            TranscriptLine(source: .microphone, start: 5, end: 9, text: "Договорились провести аудит процессов."),
            TranscriptLine(source: .meeting, start: 10, end: 14, text: "Анна: я отправлю список сотрудников в пятницу."),
            TranscriptLine(source: .microphone, start: 15, end: 19, text: "Гарантий роста прибыли мы не даём. Цена ещё обсуждается.")
        ]
        intelligence.observe(completed, directory: root)
        try await wait { intelligence.busySummary }
        guard intelligence.error.isEmpty, let summary = intelligence.record.summary else {
            throw CopilotError.message("FAIL: grounded summary: " + intelligence.error)
        }
        guard summary.citations.allSatisfy({ $0.isValid(in: completed.transcript) }),
              summary.text.lowercased().contains("аудит"), !summary.text.contains("300") else {
            throw CopilotError.message("FAIL: ungrounded synthetic summary")
        }
        let sections = summary.text.components(separatedBy: "## ")
        let decisions = sections.first { $0.hasPrefix("Договорённости") } ?? ""
        guard !decisions.lowercased().contains("скидк"), !decisions.lowercased().contains("рост") else {
            throw CopilotError.message("FAIL: proposal or negation promoted to agreement")
        }
        let restored = try IntelligenceRecord.load(directory: root)
        guard restored.summary?.text == summary.text else { throw CopilotError.message("FAIL: summary persistence") }
        print("PASS: actual local summary preserves negation, separates proposal from agreement, retains exact citations and reloads")
        let sorted = latencies.sorted()
        print("Local hint latency only (synthetic transcript, not live ASR): p50=\(sorted[4]), p95=\(sorted[9])")
    }
}
