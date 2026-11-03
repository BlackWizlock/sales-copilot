import Foundation

/// Each statement carries its own evidence. An unrelated quotation cannot ground it.
public struct GroundedMeetingNotes: Codable {
    public enum Kind: String, Codable { case topic, decision, action, question }
    public struct Fact: Codable {
        public var kind: Kind
        public var text: String
        public var owner: String
        public var deadline: String
        public var evidence: [StructuredMeetingSummary.Citation]
    }
    /// The model selects line numbers; only application code copies source evidence.
    public struct IndexedDraft: Decodable {
        public struct Entry: Decodable {
            public var kind: Kind
            public var text: String
            public var owner: String
            public var deadline: String
            public var sourceIDs: [Int]
        }
        public var facts: [Entry]

        public func grounded(in lines: [TranscriptLine], allowedSourceIDs: Set<Int>? = nil) -> GroundedMeetingNotes {
            GroundedMeetingNotes(facts: facts.map { entry in
                let valid = !entry.sourceIDs.isEmpty && entry.sourceIDs.count <= 2 &&
                    Set(entry.sourceIDs).count == entry.sourceIDs.count &&
                    entry.sourceIDs.allSatisfy { lines.indices.contains($0) && (allowedSourceIDs?.contains($0) ?? true) }
                let evidence: [StructuredMeetingSummary.Citation] = valid ? entry.sourceIDs.map {
                    .init(segmentID: lines[$0].id, quote: lines[$0].text)
                } : []
                return Fact(kind: entry.kind, text: entry.text, owner: entry.owner,
                            deadline: entry.deadline, evidence: evidence)
            })
        }
    }
    public struct Audit: Codable {
        public struct Verdict: Codable { public var index: Int; public var supported: Bool; public var kind: Kind }
        public var verdicts: [Verdict]
    }
    public var facts: [Fact]

    public func validated(in lines: [TranscriptLine], audit: Audit) -> GroundedMeetingNotes {
        var result: [Fact] = []
        for (index, original) in facts.enumerated() {
            // Missing, duplicate or conflicting verdicts fail closed for this fact.
            let verdicts = audit.verdicts.filter { $0.index == index }
            guard verdicts.count == 1, let verdict = verdicts.first, verdict.supported,
                  !original.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !original.evidence.isEmpty, original.evidence.count <= 4 else { continue }
            let sources = original.evidence.compactMap { citation -> String? in
                guard !citation.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let line = lines.first(where: { $0.id == citation.segmentID }),
                      line.text.contains(citation.quote) else { return nil }
                return citation.quote
            }
            guard sources.count == original.evidence.count else { continue }
            let evidence = sources.joined(separator: "\n")
            guard GroundedAnswer.validated(text: original.text, evidence: evidence) != nil else { continue }
            var fact = original
            // An audit may downgrade a commitment to a topic, never promote one.
            if verdict.kind != original.kind {
                guard verdict.kind == .topic else { continue }
                fact.kind = .topic
            }
            // A permissive model audit is insufficient to create a commitment.
            // Prefer omitting an uncertain task to assigning one from discussion.
            if fact.kind == .action || fact.kind == .decision {
                guard Self.hasExplicitCommitment(evidence) else { continue }
            }
            fact.owner = fact.kind == .action && !fact.owner.isEmpty && evidence.contains(fact.owner) ? fact.owner : ""
            fact.deadline = fact.kind == .action && !fact.deadline.isEmpty && evidence.contains(fact.deadline) ? fact.deadline : ""
            result.append(fact)
        }
        return GroundedMeetingNotes(facts: result)
    }

    private static func hasExplicitCommitment(_ evidence: String) -> Bool {
        let pattern = "[^\\n.!?]+[.!?]?"
        guard let parser = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(evidence.startIndex..., in: evidence)
        return parser.matches(in: evidence, range: range).contains { match in
            guard let range = Range(match.range, in: evidence) else { return false }
            let sentence = String(evidence[range]).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.hasSuffix("?"),
                  sentence.range(of: "\\b(прошл\\p{L}*|раньше|вчера|тогда|previously|yesterday)\\b", options: .regularExpression) == nil,
                  sentence.range(of: "\\b(не|нет|not|never|didn't|won't)\\b", options: .regularExpression) == nil else { return false }
            return sentence.range(of: "\\b(договорились|согласовали|подтверждаю|согласен|согласна|беру|отправлю|пришлю|сделаю|подготовлю|добавлю|внесу|проверю|agreed|confirmed)\\b|\\bi (will|'ll)\\b", options: .regularExpression) != nil || sentence == "да" || sentence == "да." || sentence == "yes" || sentence == "yes."
        }
    }

    public static func combined(_ batches: [GroundedMeetingNotes]) -> GroundedMeetingNotes {
        var seen = Set<String>()
        let facts = batches.flatMap(\.facts).filter {
            let key = $0.kind.rawValue + ":" + $0.text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return seen.insert(key).inserted
        }
        return GroundedMeetingNotes(facts: facts)
    }

    public var structured: StructuredMeetingSummary {
        let topics = facts.filter { $0.kind == .topic }.map(\.text)
        var seen = Set<UUID>()
        let citations = facts.flatMap(\.evidence).filter { seen.insert($0.segmentID).inserted }
        return StructuredMeetingSummary(
            overview: topics.isEmpty ? "Подтверждённые сведения приведены ниже." : topics.map { "- " + $0 }.joined(separator: "\n"),
            decisions: facts.filter { $0.kind == .decision }.map(\.text),
            actions: facts.filter { $0.kind == .action }.map { .init(task: $0.text, owner: $0.owner, deadline: $0.deadline) },
            questions: facts.filter { $0.kind == .question }.map(\.text), citations: citations)
    }
}
