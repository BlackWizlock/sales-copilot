import Foundation

public struct PromptExcerpt {
    public let source: String
    public let position: Int
    public let startUTF16: Int
    public let text: String
    public var renderedText: String { "[\(source), фрагмент \(position + 1), начало UTF-16 \(startUTF16)]\n\(text)\n" }
}

/// Deterministic local lexical retrieval. Originals are never modified or truncated.
/// Paragraphs retain attached conditions. Oversized units are split only at complete
/// line/sentence boundaries; indivisible oversized units are explicitly omitted.
public struct PromptContext {
    public let excerpts: [PromptExcerpt]
    public let question: String
    public let usedFallback: Bool
    public let omittedOversizedCount: Int
    public let totalExcerptCount: Int
    public let questionTooLarge: Bool
    public var renderedText: String {
        "Отобранные выдержки (\(excerpts.count) из \(totalExcerptCount)). Это часть материалов, не полный документ. Не делай вывод об отсутствии условий по отсутствию их в выдержках. Пропущено неделимых больших фрагментов: \(omittedOversizedCount). Обзорный выбор без совпадений: \(usedFallback ? "да" : "нет").\n\n"
        + excerpts.map(\.renderedText).joined(separator: "\n") + "\nПоследние целые реплики:\n" + question
    }
    public func supportingExcerpt(quote: String, source: String) -> PromptExcerpt? {
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return excerpts.first { $0.source == source && $0.text.contains(quote) }
    }
    public static func retrieve(proposal: String, deal: String, latestUtterance: String, recentUtterances: [String], perSourceBudget: Int = 12_000) -> Self {
        let budget = min(12_000, max(0, perSourceBudget))
        var questionLines: [String] = []; var questionLength = 0
        for line in (recentUtterances.filter { $0 != latestUtterance } + [latestUtterance]).reversed() {
            if questionLength + line.count + 1 <= 4_000 { questionLines.insert(line, at: 0); questionLength += line.count + 1 }
        }
        let latestTerms = terms(latestUtterance)
        let recentTerms = terms(recentUtterances.suffix(4).joined(separator: " "))
        var candidates: [(PromptExcerpt, Double)] = []; var oversized = 0
        for (name, original) in [("КП", proposal), ("Сделка", deal)] {
            let source = original as NSString
            let ranges = units(original)
            for (index, range) in ranges.enumerated() {
                let text = source.substring(with: range)
                guard text.count <= 4_000 else { oversized += 1; continue }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let tokens = terms(text)
                let score = Double(tokens.intersection(latestTerms).count * 4 + tokens.intersection(recentTerms).count) / (1 + Double(text.count) / 4_000)
                candidates.append((PromptExcerpt(source: name, position: index, startUTF16: range.location, text: text), score))
            }
        }
        let matched = candidates.filter { $0.1 > 0 }
        let fallback = matched.isEmpty
        let ranked: [(PromptExcerpt, Double)]
        if fallback {
            // No semantic guess: offer beginning/end overview, explicitly marked as fallback.
            ranked = ["КП", "Сделка"].flatMap { source -> [(PromptExcerpt, Double)] in
                let rows = candidates.filter { $0.0.source == source }
                guard let first = rows.first else { return [] }
                if let last = rows.last, last.0.position != first.0.position { return [first, last] }
                return [first]
            }
        } else {
            ranked = matched.sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.source != b.0.source { return a.0.source < b.0.source }
                return a.0.startUTF16 < b.0.startUTF16
            }
        }
        var selected: [PromptExcerpt] = []; var spent: [String: Int] = [:]
        for (excerpt, _) in ranked {
            let size = excerpt.renderedText.count + 1
            if (spent[excerpt.source] ?? 0) + size <= budget {
                selected.append(excerpt); spent[excerpt.source, default: 0] += size
            }
        }
        selected.sort { a,b in a.source == b.source ? a.startUTF16 < b.startUTF16 : a.source < b.source }
        return Self(excerpts: selected, question: questionLines.joined(separator: "\n"), usedFallback: fallback, omittedOversizedCount: oversized, totalExcerptCount: candidates.count + oversized, questionTooLarge: latestUtterance.count + 1 > 4_000)
    }
    private static func terms(_ input: String) -> Set<String> {
        let words = input.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 3 }
        let stops: Set<String> = ["какая", "какой", "какие", "это", "для", "или", "что", "как", "the", "and", "what", "are", "our", "your"]
        var result = Set(words.filter { !stops.contains($0) }.map { String($0.prefix(5)) })
        let topics = [
            ["стоим", "цен", "дорог", "бюдже", "price", "cost", "рубле"],
            ["срок", "когда", "дней", "недел", "дата", "when", "deadl", "term"],
            ["скидк", "disco"], ["оплат", "плате", "payme"], ["обуче", "train"], ["подде", "suppo"]
        ]
        for group in topics where result.contains(where: { term in group.contains(where: { term.hasPrefix($0) || $0.hasPrefix(term) }) }) {
            result.formUnion(group)
        }
        return result
    }
    private static func units(_ text: String) -> [NSRange] {
        let source = text as NSString
        func split(_ range: NSRange, pattern: String) -> [NSRange] {
            let regex = try! NSRegularExpression(pattern: pattern)
            var result: [NSRange] = []; var start = range.location
            for match in regex.matches(in: text, range: range) {
                if match.range.location > start { result.append(NSRange(location: start, length: match.range.location - start)) }
                start = NSMaxRange(match.range)
            }
            if start < NSMaxRange(range) { result.append(NSRange(location: start, length: NSMaxRange(range) - start)) }
            return result
        }
        let paragraphs = split(NSRange(location: 0, length: source.length), pattern: #"\n[\t ]*\n"#)
        var small: [NSRange] = []
        for paragraph in paragraphs {
            if paragraph.length <= 4_000 { small.append(paragraph); continue }
            let lines = split(paragraph, pattern: #"\n+"#)
            for line in lines {
                if line.length <= 4_000 { small.append(line) }
                else { small += split(line, pattern: #"(?<=[.!?。！？])\s+"#) }
            }
        }
        var joined: [NSRange] = []
        let qualifiers = ["если", "при ", "только", "кроме", "за исключением", "не включает", "эта цена", "указанная", "данная", "unless", "except", "subject", "provided", "only", "excluding"]
        for range in small {
            let value = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let previous = joined.last, qualifiers.contains(where: value.hasPrefix) {
                joined[joined.count - 1] = NSRange(location: previous.location, length: NSMaxRange(range) - previous.location)
            } else { joined.append(range) }
        }
        return joined
    }
}
