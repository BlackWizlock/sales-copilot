import Foundation

public enum PlaybackTimeline {
    public static let rates: [Double] = [0.5,0.75,1,1.25,1.5,1.75,2]
    public static func clamp(_ position: Double, duration: Double) -> Double {
        guard position.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return max(0, min(position, duration))
    }
    public static func activeLines(_ lines: [TranscriptLine], at position: Double) -> [UUID] {
        guard position.isFinite else { return [] }
        return lines.filter { $0.start.isFinite && $0.end.isFinite && $0.start <= position && position < $0.end }.map(\.id)
    }
    public static func time(_ value: Double) -> String {
        let seconds = value.isFinite ? Int(max(0, min(value, 359999))) : 0
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds/3600, seconds/60%60, seconds%60) : String(format: "%02d:%02d", seconds/60, seconds%60)
    }
}
