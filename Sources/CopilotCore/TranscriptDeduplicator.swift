import Foundation

/// A reversible projection: raw phrases and their stable identifiers are retained.
public enum TranscriptDeduplicator {
    public static func visible(_ input: [TranscriptLine]) -> [TranscriptLine] {
        var seen = Set<UUID>()
        let sorted = input.filter { seen.insert($0.id).inserted }.sorted { $0.start < $1.start }
        let reference = sorted.filter { $0.source == .meeting }.map { ($0, words($0.text)) }
        return sorted.filter { phrase in
            guard phrase.source == .microphone else { return true }
            let tokens = words(phrase.text)
            guard tokens.count >= 3 else { return true }
            return !reference.contains { other, remoteTokens in
                guard remoteTokens == tokens else { return false }
                let overlap = min(phrase.end, other.end) - max(phrase.start, other.start)
                let shortest = max(0.1, min(phrase.end - phrase.start, other.end - other.start))
                return overlap > 0 && (abs(phrase.start - other.start) <= 1.5 || overlap / shortest >= 0.5)
            }
        }
    }

    private static func words(_ value: String) -> [String] {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
