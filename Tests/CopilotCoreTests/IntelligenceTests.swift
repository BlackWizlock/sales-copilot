import Foundation
import CopilotCore

struct IntelligenceTests {
    func run() throws {
        var session = MeetingSession(title: "Synthetic")
        session.transcript = [TranscriptLine(source: .meeting, start: 2, end: 4, text: "Цена слишком высокая")]
        precondition(!IntelligenceSnapshot(session).canSummarize)
        session.state = .completed
        precondition(IntelligenceSnapshot(session).canSummarize)
        let original = IntelligenceSnapshot(session).fingerprint
        session.transcript[0].text = "Другой текст"
        precondition(original != IntelligenceSnapshot(session).fingerprint)
        session.chunks = [AudioChunk(source: .meeting, start: 0, duration: 8, filename: "test.wav")]
        precondition(!IntelligenceSnapshot(session).canSummarize)
        precondition(GroundedAnswer.validated(text: "Цена 999 рублей", evidence: "Цена 100 рублей") == nil)
        precondition(GroundedAnswer.validated(text: "Цена 100 рублей", evidence: "Цена 100 рублей") != nil)
        let citation = SummaryCitation(segmentID: session.transcript[0].id, seconds: 2, quote: "Другой текст")
        precondition(citation.isValid(in: session.transcript))
        precondition(!SummaryCitation(segmentID: UUID(), seconds: 2, quote: "Выдумано").isValid(in: session.transcript))
        let parts = IntelligenceContext.batches(["first paragraph", "middle paragraph", "last paragraph"], maxCharacters: 20)
        precondition(parts.count == 3)
        precondition(parts.joined().contains("last paragraph"))
        func notes(_ kind: String, _ text: String, _ owner: String, _ deadline: String, _ segment: UUID) throws -> GroundedMeetingNotes {
            let data = try JSONSerialization.data(withJSONObject: ["facts": [["kind": kind, "text": text,
                "owner": owner, "deadline": deadline, "evidence": [["segmentID": segment.uuidString, "quote": text]]]]])
            return try JSONDecoder().decode(GroundedMeetingNotes.self, from: data)
        }
        let sourceA = UUID(), sourceB = UUID()
        let firstTopic = try notes("topic", "Обсудили обучение.", "", "", sourceA)
        let repeatedTopic = try notes("topic", "Обсудили обучение.", "", "", sourceB)
        let combinedTopics = GroundedMeetingNotes.combined([firstTopic, repeatedTopic, firstTopic])
        precondition(combinedTopics.facts.count == 1 && combinedTopics.structured.citations.count == 2,
                     "Removing a repeated summary topic must preserve distinct supporting quotations")
        let literalDecision = try notes("decision", "Договорились провести аудит.", "", "", sourceA)
        let conciseDecision = try notes("decision", "Провести аудит.", "", "", sourceB)
        let combinedDecision = GroundedMeetingNotes.combined([literalDecision, conciseDecision])
        precondition(combinedDecision.structured.decisions.count == 1 && combinedDecision.structured.citations.count == 2,
                     "Equivalent literal agreement prefix must not duplicate a decision or lose its quotations")
        let firstTask = try notes("action", "Отправить документы.", "Анна", "пятница", sourceA)
        let secondTask = try notes("action", "Отправить документы.", "Иван", "понедельник", sourceB)
        let combinedTasks = GroundedMeetingNotes.combined([firstTask, secondTask])
        precondition(combinedTasks.structured.actions.count == 2,
                     "Identical task wording for different owners or deadlines must remain separate")
        print("PASS: summary deduplication preserves source quotations and distinct assignments")
        func checkedCommitment(_ evidence: String) throws -> GroundedMeetingNotes {
            let line = TranscriptLine(source: .meeting, start: 0, end: 4, text: evidence)
            let draft = try JSONDecoder().decode(GroundedMeetingNotes.IndexedDraft.self,
                from: JSONSerialization.data(withJSONObject: ["facts": [["kind": "action",
                    "text": "Проверить площадку.", "owner": "", "deadline": "", "sourceIDs": [0]]]]))
            let audit = try JSONDecoder().decode(GroundedMeetingNotes.Audit.self,
                from: JSONSerialization.data(withJSONObject: ["verdicts": [["index": 0, "supported": true, "kind": "action"]]]))
            return draft.grounded(in: [line]).validated(in: [line], audit: audit)
        }
        let currentPromise = try checkedCommitment("Да, я тогда пробью площадку.")
        precondition(currentPromise.facts.count == 1,
                     "A present first-person promise with тогда must survive summary validation")
        for past in ["Тогда договорились проверить площадку.", "Вчера я договорился проверить площадку.",
                     "Я тогда пробил площадку.", "Я тогда сказал, что я проверю площадку.",
                     "Я тогда думал, что я отправлю запрос.", "Я тогда не пробью площадку.", "Я тогда пробью площадку?"] {
            let pastResult = try checkedCommitment(past)
            precondition(pastResult.facts.isEmpty,
                         "Historical, negated and interrogative statements must not create current tasks")
        }
        print("PASS: current promises survive тогда while past, negation and questions stay excluded")
        func corrected(_ source: String, original: String, audited: String, owner: String = "", deadline: String = "", text: String? = nil) throws -> GroundedMeetingNotes {
            let line = TranscriptLine(source: .meeting, start: 0, end: 4, text: source)
            let draft = try JSONDecoder().decode(GroundedMeetingNotes.IndexedDraft.self,
                from: JSONSerialization.data(withJSONObject: ["facts": [["kind": original,
                    "text": text ?? source, "owner": "", "deadline": "", "sourceIDs": [0]]]]))
            let audit = try JSONDecoder().decode(GroundedMeetingNotes.Audit.self,
                from: JSONSerialization.data(withJSONObject: ["verdicts": [["index": 0, "supported": true,
                    "kind": audited, "owner": owner, "deadline": deadline]]]))
            return draft.grounded(in: [line]).validated(in: [line], audit: audit)
        }
        let decisionCorrection = try corrected("Договорились провести аудит процессов.", original: "action", audited: "decision")
        precondition(decisionCorrection.structured.decisions.count == 1,
                     "Audit must correct a proposed commitment's category using explicit agreement")
        for agreement in ["Согласен провести аудит процессов.", "Согласна провести аудит процессов.",
                          "Подтверждаю проведение аудита процессов.", "Решили провести аудит процессов."] {
            let accepted = try corrected(agreement, original: "decision", audited: "decision")
            precondition(accepted.structured.decisions.count == 1,
                         "Explicit expanded acceptance and decisions must survive the decision guard")
        }
        let missedClassification = try corrected("Договорились провести аудит процессов.", original: "action", audited: "action")
        precondition(missedClassification.structured.decisions.count == 1,
                     "Unambiguous source agreement must determine status even when both model passes misclassify it")
        let mixedSource = try corrected("Договорились провести аудит. Я отправлю список сотрудников.", original: "action", audited: "action", text: "Отправить список сотрудников.")
        precondition(mixedSource.structured.actions.count == 1 && mixedSource.structured.decisions.isEmpty,
                     "A separate agreement in the same source must not reclassify a personal action")
        let sameSentence = try corrected("Договорились провести аудит, а я отправлю список сотрудников.", original: "action", audited: "action", text: "Отправить список сотрудников.")
        precondition(sameSentence.structured.actions.count == 1 && sameSentence.structured.decisions.isEmpty,
                     "Agreement about another action in the same sentence must not change this action's status")
        for source in ["В пятницу у меня отпуск. Я отправлю список сотрудников.",
                       "Я отправлю список сотрудников, а в пятницу у меня отпуск."] {
            let unrelatedDate = try corrected(source, original: "action", audited: "action", text: "Отправить список сотрудников.")
            precondition(unrelatedDate.structured.actions.first?.deadline == "", "A date outside the validated action must not become its deadline")
        }
        let missedDeadline = try corrected("Анна: я отправлю список сотрудников в пятницу.", original: "action", audited: "action", owner: "Анна")
        precondition(missedDeadline.structured.actions.first?.deadline == "в пятницу",
                     "A single explicit weekday deadline must not remain unknown after a model omission")
        let normalizedWeekday = try corrected("Анна: я отправлю список сотрудников в пятницу.", original: "action", audited: "action", owner: "Анна", deadline: "пятница")
        precondition(normalizedWeekday.structured.actions.first?.deadline == "в пятницу",
                     "A model-normalized weekday must recover its exact form from the validated action")
        let environment = try corrected("Я проверю настройки в среде разработки.", original: "action", audited: "action")
        precondition(environment.structured.actions.first?.deadline == "", "An environment is not a weekday deadline")
        let coverageSources = ["Договорились провести аудит.", "Вчера договорились провести аудит.",
                               "Договорились провести аудит?", "Не договорились провести аудит.",
                               "Я сказал, что договорились провести аудит.",
                               "Договорились провести аудит, а я отправлю список."]
        let coverageLines = coverageSources.enumerated().map { index, source in
            TranscriptLine(source: .meeting, start: Double(index), end: Double(index + 1), text: source)
        }
        let covered = GroundedMeetingNotes.explicitDecisions(in: coverageLines, allowedSourceIDs: Set(coverageLines.indices))
        precondition(covered.facts.count == 1 && covered.facts.first?.evidence.first?.quote == coverageSources[0],
                     "Standalone decision coverage must not seed history, questions, negation, reported speech or mixed clauses")
        precondition(GroundedMeetingNotes.explicitDecisions(in: coverageLines, allowedSourceIDs: []).facts.isEmpty,
                     "Coverage must respect the current source batch")
        let ambiguousDeadline = try corrected("Я отправлю список в пятницу или в понедельник.", original: "action", audited: "action")
        precondition(ambiguousDeadline.structured.actions.first?.deadline == "", "Do not choose between alternative explicit dates")
        let assignmentCorrection = try corrected("Анна: я отправлю список сотрудников в пятницу.", original: "action", audited: "action", owner: "Анна", deadline: "в пятницу")
        precondition(assignmentCorrection.structured.actions.first?.owner == "Анна" && assignmentCorrection.structured.actions.first?.deadline == "в пятницу",
                     "Explicit owner and deadline omitted by extraction must be restored from audited source")
        let promotion = try corrected("Договорились провести аудит процессов.", original: "topic", audited: "decision")
        precondition(promotion.facts.isEmpty, "Audit must never promote an extracted topic into a commitment")
        let falseMutualDecision = try corrected("Я отправлю список сотрудников.", original: "action", audited: "decision")
        precondition(falseMutualDecision.facts.isEmpty, "A personal promise alone must not become a mutual decision")
        let inventedMetadata = try corrected("Анна: я отправлю список сотрудников в пятницу.", original: "action", audited: "action", owner: "Иван", deadline: "в понедельник")
        precondition(inventedMetadata.structured.actions.first?.owner == "" && inventedMetadata.structured.actions.first?.deadline == "в пятницу",
                     "Invented metadata must not survive; an exact validated task deadline may replace it")
        print("PASS: audited commitments retain correct category and explicit literal owner/deadline without promotion")
        var ledger = CloudBudgetLedger(day: "synthetic")
        do { try ledger.reserve(0.01, limit: 0, day: "synthetic"); preconditionFailure("Zero budget must block") } catch {}
        try ledger.reserve(0.01, limit: 0.02, day: "synthetic")
        precondition(ledger.charged == 0.01)
        do { try ledger.reserve(0.02, limit: 0.02, day: "synthetic"); preconditionFailure("Over budget must block") } catch {}
        precondition(ledger.charged == 0.01)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var record = IntelligenceRecord()
        record.proposalText = "Synthetic proposal 100 рублей"
        record.summary = MeetingSummary(text: "Договорились", transcriptFingerprint: original, model: "synthetic", citations: [citation])
        try record.save(directory: root)
        try record.save(directory: root)
        let loaded = try IntelligenceRecord.load(directory: root)
        precondition(loaded.proposalText == record.proposalText)
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("intelligence.json").path)[.posixPermissions] as? Int
        precondition(mode == 0o600)
        print("PASS: intelligence completion, freshness, numerical grounding, citations")
    }
}
