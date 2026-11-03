import Foundation
import CopilotCore

struct PlaybackTests {
    func run() {
        let a = TranscriptLine(source: .microphone, start: 1, end: 3, text: "a")
        let b = TranscriptLine(source: .meeting, start: 2, end: 4, text: "b")
        let invalid = TranscriptLine(source: .meeting, start: .nan, end: .infinity, text: "bad")
        expectEqual(PlaybackTimeline.activeLines([a,b,invalid], at: 0), [])
        expectEqual(PlaybackTimeline.activeLines([a,b], at: 1), [a.id])
        expectEqual(PlaybackTimeline.activeLines([a,b], at: 2), [a.id,b.id])
        expectEqual(PlaybackTimeline.activeLines([a,b], at: 3), [b.id])
        expectEqual(PlaybackTimeline.activeLines([a,b], at: 4), [])
        expectEqual(PlaybackTimeline.activeLines([a,b], at: .nan), [])
        expectEqual(PlaybackTimeline.clamp(.nan, duration: 20), 0)
        expectEqual(PlaybackTimeline.clamp(30, duration: 20), 20)
        expectEqual(PlaybackTimeline.clamp(-2, duration: 20), 0)
        expectEqual(PlaybackTimeline.clamp(2, duration: .infinity), 0)
        expectEqual(PlaybackTimeline.rates, [0.5,0.75,1,1.25,1.5,1.75,2])
        print("PASS: playback overlap, gaps, invalid positions and rates")
    }
}
