import Foundation
import CopilotCore

/// Explicitly authorized cloud inference with synthetic documents and dialogue. No credentials or CRM writes.
@MainActor enum MeetingWorkflowVerification {
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<3000 {
            if !predicate() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CopilotError.message("FAIL: cloud workflow exceeded five minutes")
    }
    @MainActor static func run() async throws {
        let runtime = IntelligenceRuntime.shared
        guard ProcessInfo.processInfo.environment["AXIS_COPILOT_ALLOW_PAID_SYNTHETIC_TEST"] == "1" else {
            throw CopilotError.message("Paid synthetic workflow is opt-in; no model request was sent")
        }
        print("Selected OpenRouter model: " + runtime.activeModel); fflush(stdout)
        var terms = MeetingSession(title: "Synthetic summary coverage")
        terms.state = .completed
        terms.transcript = [
            TranscriptLine(source: .meeting, start: 0, end: 4, text: "Добрый день!"),
            TranscriptLine(source: .microphone, start: 0.5, end: 3, text: "*музыка*"),
            TranscriptLine(source: .meeting, start: 8, end: 12, text: "Мы обсуждаем коммерческое предложение, стоимость протеин."),
            TranscriptLine(source: .microphone, start: 8.5, end: 10, text: "Да, время!"),
            TranscriptLine(source: .meeting, start: 16, end: 20, text: "Срок выполнения работы 4 недели."),
            TranscriptLine(source: .microphone, start: 16.5, end: 18, text: "*музыка*"),
            TranscriptLine(source: .meeting, start: 20.2, end: 21, text: "Добрый день!"),
            TranscriptLine(source: .meeting, start: 21.2, end: 24, text: "Мы обсуждаем коммерческое предложение."),
            TranscriptLine(source: .meeting, start: 24, end: 28, text: "Своимость проекта составляет 100 тысяч рублей, срок выполнения"),
            TranscriptLine(source: .microphone, start: 24.5, end: 26, text: "[музыка]"),
            TranscriptLine(source: .meeting, start: 27.9, end: 32, text: "работы 4 недели.")
        ]
        let coverage = try await GroundedSummaryGenerator(runtime: .shared).generate(IntelligenceSnapshot(terms)) { print($0); fflush(stdout) }
        let coverageText = coverage.markdown.lowercased()
        guard coverageText.contains("100"), coverageText.contains("4"), coverageText.contains("недел"),
              coverage.citations.allSatisfy({ citation in terms.transcript.contains { $0.id == citation.segmentID && $0.text.contains(citation.quote) } }) else {
            throw CopilotError.message("FAIL: summary omitted explicit price or duration from synthetic recorded transcript: " + coverage.markdown)
        }
        guard !coverage.overview.lowercased().contains("протеин"), !coverage.overview.lowercased().contains("музык") else {
            throw CopilotError.message("FAIL: summary promoted an incoherent recognition fragment into a meaningful topic: " + coverage.overview)
        }
        print("PASS: real cloud summary retains explicit price and duration in fragmented synthetic ASR"); fflush(stdout)
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
        // These are business outcomes, not a nonempty-response check. A hint
        // using the wrong price, omitting scope or inventing a discount must fail.
        let expectedHintTerms = [
            [#"120\s*000|120\s*тыс"#], [#"10"#, #"рабоч"#],
            [#"интервью"#, #"карт"#], [#"отч[её]т"#, #"план"#],
            [#"50"#, #"аванс|предоплат"#], [#"телемост"#], [#"отдельн"#],
            [#"дв[еа]|2"#, #"встреч"#],
            [#"уточн|не\s+(указан|обсужд|определ[её]н|предусмотрен)|нет.*(информац|данных)"#],
            [#"не.*гарант|гарант.*не|уточн|не\s+указан|нет.*информац"#]
        ]
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
            guard expectedHintTerms[index].allSatisfy({ pattern in
                intelligence.suggestion.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }) else {
                throw CopilotError.message("FAIL: automatic hint did not answer the synthetic business question \(index + 1): " + intelligence.suggestion)
            }
            latencies.append(Date().timeIntervalSince(started))
            print("PASS: automatic synthetic objection \(index + 1), seconds \(latencies.last!)"); fflush(stdout)
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
        intelligence.summarize()
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
        let nextSteps = sections.first { $0.hasPrefix("Следующие шаги") } ?? ""
        guard decisions.lowercased().contains("аудит"), nextSteps.contains("Анна"),
              nextSteps.lowercased().contains("список сотрудников"), nextSteps.lowercased().contains("пятницу"),
              !nextSteps.lowercased().contains("срок не назван"), !nextSteps.lowercased().contains("ответственный не назван") else {
            throw CopilotError.message("FAIL: summary omitted an explicit decision, action, owner or deadline: " + summary.text)
        }
        let restored = try IntelligenceRecord.load(directory: root)
        guard restored.summary?.text == summary.text else { throw CopilotError.message("FAIL: summary persistence") }
        print("PASS: actual local summary preserves negation, separates proposal from agreement, retains exact citations and reloads")
        let sorted = latencies.sorted()
        print("Local hint latency only (synthetic transcript, not live ASR): p50=\(sorted[4]), p95=\(sorted[9])")
    }
}
