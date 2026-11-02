import Foundation

public struct SpeakerProfile: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct SpeakerTurn: Codable, Identifiable, Equatable {
    public var id: String
    public var source: AudioSource
    public var start: Double
    public var end: Double
    public var speakerID: String?
    /// Model segment quality, not a calibrated probability of identity.
    public var confidence: Float
    public var isOverlap: Bool
    public init(source: AudioSource, start: Double, end: Double, speakerID: String?, confidence: Float, isOverlap: Bool = false) {
        self.source = source; self.start = start; self.end = end; self.speakerID = speakerID
        self.confidence = confidence; self.isOverlap = isOverlap
        self.id = "\(source.rawValue):\(Int((start * 1000).rounded())):\(Int((end * 1000).rounded())):\(speakerID ?? "unknown")"
    }
}

public struct SpeakerOverride: Codable, Equatable {
    public var phraseID: UUID
    /// nil explicitly means unknown, rather than absence of a correction.
    public var speakerID: String?
    public init(phraseID: UUID, speakerID: String?) { self.phraseID = phraseID; self.speakerID = speakerID }
}

extension MeetingSession {
    public func speakerID(for line: TranscriptLine) -> String? {
        if let manual = speakerOverrides?.first(where: { $0.phraseID == line.id }) { return manual.speakerID }
        guard line.end > line.start else { return nil }
        let matching = (speakerTurns ?? []).filter {
            $0.source == line.source && min($0.end, line.end) > max($0.start, line.start)
        }
        guard !matching.contains(where: { $0.isOverlap }) else { return nil }
        let ids = Set(matching.compactMap { turn -> String? in
            guard turn.confidence >= 0.25 else { return nil }
            return turn.speakerID
        })
        guard ids.count == 1, let id = ids.first else { return nil }
        // Do not infer a whole phrase from a tiny detected portion.
        let covered = matching.filter { $0.speakerID == id && $0.confidence >= 0.25 }
            .reduce(0.0) { $0 + min($1.end, line.end) - max($1.start, line.start) }
        return covered / (line.end - line.start) >= 0.5 ? id : nil
    }

    public mutating func setSpeakerOverride(phraseID: UUID, speakerID: String?) {
        var values = speakerOverrides ?? []
        values.removeAll { $0.phraseID == phraseID }
        values.append(SpeakerOverride(phraseID: phraseID, speakerID: speakerID))
        speakerOverrides = values
    }

    /// Reconcile labels only on strong, unambiguous temporal correspondence.
    /// Names and phrase corrections are retained even when a rerun is ambiguous.
    public mutating func applySpeakerTurns(_ incoming: [SpeakerTurn]) {
        let previous = speakerTurns ?? []
        var mapping: [String: String] = [:]
        var used = Set<String>()
        for id in Set(incoming.compactMap(\.speakerID)).sorted() {
            let fresh = incoming.filter { $0.speakerID == id && !$0.isOverlap }
            let duration = fresh.reduce(0) { $0 + max(0, $1.end - $1.start) }
            var scores: [String: Double] = [:]
            for a in fresh {
                for b in previous where a.source == b.source && !b.isOverlap {
                    if let oldID = b.speakerID {
                        scores[oldID, default: 0] += max(0, min(a.end, b.end) - max(a.start, b.start))
                    }
                }
            }
            let ranked = scores.sorted { $0.value > $1.value }
            if duration > 0, let best = ranked.first, best.value / duration >= 0.75,
               (ranked.count < 2 || ranked[1].value / duration < 0.2), !used.contains(best.key) {
                mapping[id] = best.key; used.insert(best.key)
            }
        }
        // Engines commonly restart numeric labels at 1 on every analysis.
        // An unmatched recycled label must never acquire an unrelated saved name.
        for id in Set(incoming.compactMap(\.speakerID)) where mapping[id] == nil {
            if (speakers ?? []).contains(where: { $0.id == id }) { mapping[id] = UUID().uuidString }
        }
        speakerTurns = incoming.map { turn in
            var copy = turn
            if let id = turn.speakerID, let existing = mapping[id] { copy.speakerID = existing }
            copy.id = SpeakerTurn(source: copy.source, start: copy.start, end: copy.end, speakerID: copy.speakerID, confidence: copy.confidence, isOverlap: copy.isOverlap).id
            return copy
        }
        var profiles = speakers ?? []
        for id in Set((speakerTurns ?? []).compactMap(\.speakerID)).sorted() where !profiles.contains(where: { $0.id == id }) {
            profiles.append(SpeakerProfile(id: id, name: "Участник \(profiles.count + 1)"))
        }
        speakers = profiles
    }
}
