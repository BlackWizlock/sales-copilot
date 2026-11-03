import Foundation
import CopilotCore

struct SpeakerTests {
    func run() throws {
        var original = MeetingSession(title: "Old")
        let old = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MeetingSession.self, from: old)
        expectEqual(decoded.speakers, nil)
        let line = TranscriptLine(source: .meeting, start: 1, end: 3, text: "Test")
        original.transcript = [line]
        let first = SpeakerTurn(source: .meeting, start: 0, end: 4, speakerID: "a", confidence: 0.9)
        original.applySpeakerTurns([first])
        original.speakers?[0].name = "Артём"
        original.setSpeakerOverride(phraseID: line.id, speakerID: "manual")
        original.applySpeakerTurns([SpeakerTurn(source: .meeting, start: 0, end: 4, speakerID: "changed", confidence: 0.9)])
        expectEqual(original.speakers?.first?.name, "Артём")
        expectEqual(original.speakerID(for: line), "manual")
        original.setSpeakerOverride(phraseID: line.id, speakerID: nil)
        expectEqual(original.speakerID(for: line), nil)
        original.speakerOverrides = nil
        expectEqual(original.speakerID(for: line), "a")
        original.speakerTurns?.append(SpeakerTurn(source: .meeting, start: 2, end: 3, speakerID: "b", confidence: 0.9))
        expectEqual(original.speakerID(for: line), nil)
        original.speakerTurns = [SpeakerTurn(source: .meeting, start: 0, end: 4, speakerID: "a", confidence: 0.2)]
        expectEqual(original.speakerID(for: line), nil)
        let roundtrip = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(original))
        expectEqual(roundtrip.speakers?.first?.name, "Артём")
        var ambiguous = MeetingSession(title: "Ambiguous")
        ambiguous.applySpeakerTurns([SpeakerTurn(source: .meeting, start: 0, end: 2, speakerID: "1", confidence: 0.9)])
        ambiguous.speakers?[0].name = "Saved name"
        ambiguous.applySpeakerTurns([SpeakerTurn(source: .meeting, start: 5, end: 7, speakerID: "1", confidence: 0.9)])
        precondition(ambiguous.speakerTurns?.first?.speakerID != "1", "Fresh model label must not inherit an unrelated saved name")
        let simultaneousA = SpeakerTurn(source: .meeting, start: 1, end: 2, speakerID: "a", confidence: 0.9)
        let simultaneousB = SpeakerTurn(source: .meeting, start: 1, end: 2, speakerID: "b", confidence: 0.9)
        precondition(simultaneousA.id != simultaneousB.id, "Concurrent turns need distinct stable IDs")
        print("PASS: speaker backward compatibility, overlap, confidence, name preservation, manual overrides")
    }
}
