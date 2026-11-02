import Foundation
import CryptoKit

public struct IntelligenceSnapshot {
    public let session: MeetingSession
    public init(_ session: MeetingSession) { self.session = session }
    public var canSummarize: Bool {
        session.state == .completed && !session.transcript.isEmpty && session.chunks.allSatisfy { $0.state == .completed }
    }
    public var fingerprint: String {
        let content = session.id.uuidString + session.transcript.map { "\($0.id)|\($0.start)|\($0.end)|\($0.text)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public var transcriptText: String {
        TranscriptDeduplicator.visible(session.transcript).map { "[\($0.id.uuidString) @ \(Int($0.start))s] \($0.source.title): \($0.text)" }.joined(separator: "\n")
    }
}

public enum GroundedAnswer {
    /// Conservative numerical guard: every numeric token must occur in the supplied evidence.
    public static func validated(text: String, evidence: String) -> String? {
        let regex = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d+)?"#)
        func numbers(_ value: String) -> Set<String> {
            Set(regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { Range($0.range, in: value).map { String(value[$0]) } })
        }
        guard numbers(text).isSubset(of: numbers(evidence)), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

public enum IntelligenceContext {
    /// Preserve every paragraph, including a long final paragraph, across bounded requests.
    public static func batches(_ items: [String], maxCharacters: Int = 24_000) -> [String] {
        var result: [String] = []; var current = ""
        for item in items {
            if !current.isEmpty && current.count + item.count > maxCharacters { result.append(current); current = "" }
            current += item + "\n"
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

public struct CloudBudgetLedger: Codable {
    public private(set) var day: String
    public private(set) var charged: Decimal
    public init(day: String, charged: Decimal = 0) { self.day = day; self.charged = charged }
    public mutating func reserve(_ amount: Decimal, limit: Decimal, day: String) throws {
        guard !amount.isNaN, !limit.isNaN, amount >= 0, limit > 0 else { throw CopilotError.message("Облачный бюджет не задан") }
        let current: Decimal = self.day == day ? charged : 0
        guard current + amount <= limit else { throw CopilotError.message("Дневной бюджет OpenRouter исчерпан") }
        self.day = day; charged = current + amount
    }
    public mutating func reconcile(reserved: Decimal, actual: Decimal?) {
        guard let actual, !actual.isNaN, actual >= 0 else { return }
        charged = max(0, charged - reserved + actual)
    }
}
