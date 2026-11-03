import Foundation
import CopilotCore

@MainActor enum PlaybackVerification {
    static func run() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axis-playback-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try WaveFile.encode((0..<96000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000)) * 0.1 }).write(to: url)
        let playback = PlaybackController()
        let savedRate = playback.rate
        defer { playback.stop(); playback.rate = savedRate }
        try playback.load(url: url)
        playback.volume = 0
        guard abs(playback.duration - 6) < 0.01 else { throw CopilotError.message("Incorrect playback duration") }
        for rate in PlaybackTimeline.rates {
            playback.rate = rate; playback.seek(to: 1); playback.play()
            try await Task.sleep(for: .milliseconds(400))
            playback.pause()
            let advanced = playback.position - 1
            guard abs(advanced - 0.4 * rate) < 0.22, !playback.isPlaying else { throw CopilotError.message("Playback rate/pause failed at \(rate): \(advanced)") }
            let paused = playback.position
            try await Task.sleep(for: .milliseconds(100))
            guard playback.position == paused else { throw CopilotError.message("Pause did not freeze playback") }
            playback.seek(to: 2)
            guard playback.position == 2, playback.rate == rate else { throw CopilotError.message("Seek lost rate/position") }
        }
        playback.seek(to: .nan)
        guard playback.position == 0 else { throw CopilotError.message("Invalid seek not clamped") }
        playback.seek(to: 6); playback.play()
        try await Task.sleep(for: .milliseconds(150))
        playback.pause()
        guard playback.position < 1 else { throw CopilotError.message("End did not restart from zero") }
        playback.stop()
        guard !playback.isLoaded, playback.duration == 0, !playback.isPlaying else { throw CopilotError.message("Stop did not clear previous meeting") }
        print("PASS: real audio playback at all seven rates, pause, seek, end restart and stop; output muted")
    }
}
