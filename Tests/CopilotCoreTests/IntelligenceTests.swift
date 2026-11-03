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
        let firstTask = try notes("action", "Отправить документы.", "Анна", "пятница", sourceA)
        let secondTask = try notes("action", "Отправить документы.", "Иван", "понедельник", sourceB)
        let combinedTasks = GroundedMeetingNotes.combined([firstTask, secondTask])
        precondition(combinedTasks.structured.actions.count == 2,
                     "Identical task wording for different owners or deadlines must remain separate")
        print("PASS: summary deduplication preserves source quotations and distinct assignments")
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
