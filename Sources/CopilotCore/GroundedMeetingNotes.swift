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
        public init(facts: [Entry]) { self.facts = facts }

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
        public struct Verdict: Codable {
            public var index: Int
            public var supported: Bool
            public var kind: Kind
            public var owner: String?
            public var deadline: String?
        }
        public var verdicts: [Verdict]
    }
    public var facts: [Fact]

    /// High-precision coverage of literal, standalone Russian agreements.
    /// These remain candidates and undergo the same independent audit as model facts.
    public static func explicitDecisions(in lines: [TranscriptLine], allowedSourceIDs: Set<Int>) -> GroundedMeetingNotes {
        let facts = lines.indices.filter { allowedSourceIDs.contains($0) }.compactMap { index -> Fact? in
            let line = lines[index]
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count <= 240, isSingleDecision(text),
                  text.rangeOfCharacter(from: CharacterSet(charactersIn: ",;:")) == nil,
                  text.range(of: "^(?:мы\\s+)?(?:договорились|согласовали|решили)\\b", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
            return Fact(kind: .decision, text: text, owner: "", deadline: "",
                        evidence: [.init(segmentID: line.id, quote: line.text)])
        }
        return GroundedMeetingNotes(facts: facts)
    }

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
            // Reclassify an already proposed commitment, but never promote topics
            // or questions into obligations. The source still has to prove its status.
            if verdict.kind != original.kind {
                let commitments: Set<Kind> = [.action, .decision]
                guard verdict.kind == .topic ||
                    (commitments.contains(original.kind) && commitments.contains(verdict.kind)) else { continue }
                fact.kind = verdict.kind
            }
            if (fact.kind == .action || fact.kind == .decision) && sources.count == 1 && Self.isSingleDecision(original.text) && Self.hasExplicitDecision(evidence) {
                fact.kind = .decision
            }
            if fact.kind == .decision {
                let mutualAgreement = Self.hasExplicitDecision(evidence)
                let directAcceptance = sources.count >= 2 && sources.contains {
                    ["да", "да.", "yes", "yes."].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                }
                guard mutualAgreement || directAcceptance else { continue }
            }
            // A permissive model audit is insufficient to create a commitment.
            // Prefer omitting an uncertain task to assigning one from discussion.
            if fact.kind == .action || fact.kind == .decision {
                guard Self.hasExplicitCommitment(evidence) else { continue }
            }
            let owner = verdict.owner ?? fact.owner
            var deadline = verdict.deadline ?? fact.deadline
            if (deadline.isEmpty || !evidence.contains(deadline)) && fact.kind == .action && sources.count == 1 {
                deadline = Self.singleExplicitDeadline(original.text) ?? ""
            }
            fact.owner = fact.kind == .action && !owner.isEmpty && evidence.contains(owner) ? owner : ""
            fact.deadline = fact.kind == .action && !deadline.isEmpty && evidence.contains(deadline) ? deadline : ""
            result.append(fact)
        }
        return GroundedMeetingNotes(facts: result)
    }

    private static func isSingleDecision(_ evidence: String) -> Bool {
        let sentences = evidence.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return sentences.count == 1 && hasExplicitDecision(evidence)
    }

    private static func hasExplicitDecision(_ evidence: String) -> Bool {
        evidence.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).contains { raw in
            let sentence = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !evidence.contains(raw + "?"),
                  sentence.range(of: "\\b(не|нет|not|never|прошл\\p{L}*|раньше|вчера|тогда|previously|yesterday)\\b", options: .regularExpression) == nil else { return false }
            return sentence.range(of: "\\b(договорились|согласовали|решили|подтверждаю|согласен|согласна|согласован[аоы]?|agreed|confirmed)\\b", options: .regularExpression) != nil
        }
    }

    private static func singleExplicitDeadline(_ evidence: String) -> String? {
        let pattern = "\\b(?:в\\s+(?:понедельник|вторник|среду|четверг|пятницу|субботу|воскресенье)|до\\s+(?:понедельника|вторника|среды|четверга|пятницы|субботы|воскресенья)|к\\s+(?:понедельнику|вторнику|среде|четвергу|пятнице|субботе|воскресенью)|сегодня|завтра|послезавтра)\\b"
        guard let parser = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let matches = parser.matches(in: evidence, range: NSRange(evidence.startIndex..., in: evidence))
        guard matches.count == 1, let match = matches.first, let range = Range(match.range, in: evidence) else { return nil }
        return String(evidence[range])
    }

    private static func hasExplicitCommitment(_ evidence: String) -> Bool {
        let pattern = "[^\\n.!?]+[.!?]?"
        guard let parser = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(evidence.startIndex..., in: evidence)
        return parser.matches(in: evidence, range: range).contains { match in
            guard let range = Range(match.range, in: evidence) else { return false }
            let sentence = String(evidence[range]).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.hasSuffix("?"),
                  sentence.range(of: "\\b(прошл\\p{L}*|раньше|вчера|previously|yesterday)\\b", options: .regularExpression) == nil,
                  sentence.range(of: "\\b(не|нет|not|never|didn't|won't)\\b", options: .regularExpression) == nil else { return false }
            // Тогда can mean "in that case" in a current promise. Require an
            // explicit first-person future form rather than treating past agreement
            // ("тогда договорились") as a new assignment.
            let future = "(?:отправлю|пришлю|сделаю|подготовлю|добавлю|внесу|проверю|пробью|уточню|свяжусь|узнаю|организую|согласую|запрошу)"
            let firstPersonFuture = sentence.range(of: "^(?:(?:да|окей|хорошо|ладно)[,;:]?\\s+)*(?:тогда\\s+)?я\\s+(?:тогда\\s+)?" + future + "\\b", options: .regularExpression) != nil
            if sentence.range(of: "\\bтогда\\b", options: .regularExpression) != nil { return firstPersonFuture }
            if firstPersonFuture { return true }
            return sentence.range(of: "\\b(договорились|согласовали|решили|подтверждаю|согласен|согласна|беру|отправлю|пришлю|сделаю|подготовлю|добавлю|внесу|проверю|agreed|confirmed)\\b|\\bi (will|'ll)\\b", options: .regularExpression) != nil || sentence == "да" || sentence == "да." || sentence == "yes" || sentence == "yes."
        }
    }

    public static func combined(_ batches: [GroundedMeetingNotes]) -> GroundedMeetingNotes {
        struct Identity: Hashable { let kind: String; let text: String; let owner: String; let deadline: String }
        func normalized(_ text: String) -> String {
            text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        var positions: [Identity: Int] = [:]
        var facts: [Fact] = []
        for fact in batches.flatMap(\.facts) {
            var text = normalized(fact.text)
            if fact.kind == .decision {
                text = text.trimmingCharacters(in: .punctuationCharacters)
                    .replacingOccurrences(of: "^(?:мы\\s+)?(?:договорились|согласовали|решили)\\s+", with: "", options: .regularExpression)
            }
            let key = Identity(kind: fact.kind.rawValue, text: text,
                               owner: normalized(fact.owner), deadline: normalized(fact.deadline))
            if let index = positions[key] {
                for citation in fact.evidence where !facts[index].evidence.contains(where: {
                    $0.segmentID == citation.segmentID && $0.quote == citation.quote
                }) {
                    facts[index].evidence.append(citation)
                }
            } else {
                positions[key] = facts.count
                facts.append(fact)
            }
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
