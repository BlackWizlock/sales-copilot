import AVFoundation
import SwiftUI
import CopilotCore

@MainActor final class PlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoaded = false
    @Published var error: String?
    @Published var rate: Double {
        didSet {
            guard PlaybackTimeline.rates.contains(rate) else { rate = 1; return }
            player?.rate = Float(rate)
            UserDefaults.standard.set(rate, forKey: "playbackRate")
        }
    }
    @Published var volume = 0.8 { didSet { player?.volume = Float(max(0, min(1, volume))) } }
    private var player: AVAudioPlayer?
    private var url: URL?
    private var timer: Timer?

    override init() {
        let saved = UserDefaults.standard.double(forKey: "playbackRate")
        rate = PlaybackTimeline.rates.contains(saved) ? saved : 1
        super.init()
    }
    func load(url: URL) throws {
        if self.url == url && isLoaded { return }
        stop()
        let audio = try AVAudioPlayer(contentsOf: url)
        guard audio.duration.isFinite, audio.duration > 0 else { throw CopilotError.message("Аудиофайл пуст или повреждён") }
        audio.enableRate = true
        audio.rate = Float(rate)
        audio.volume = Float(volume)
        audio.delegate = self
        guard audio.prepareToPlay() else { throw CopilotError.message("Не удалось подготовить аудио") }
        player = audio; self.url = url; duration = audio.duration; isLoaded = true; error = nil
    }
    func toggle() { isPlaying ? pause() : play() }
    func play() {
        guard let player else { return }
        if position >= duration { seek(to: 0) }
        player.rate = Float(rate)
        guard player.play() else { error = "Не удалось начать воспроизведение"; return }
        isPlaying = true
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func pause() {
        player?.pause(); refresh(); isPlaying = false
        timer?.invalidate(); timer = nil
    }
    func seek(to seconds: Double) {
        position = PlaybackTimeline.clamp(seconds, duration: duration)
        player?.currentTime = position
    }
    func stop() {
        timer?.invalidate(); timer = nil; player?.stop(); player = nil; url = nil
        position = 0; duration = 0; isPlaying = false; isLoaded = false; error = nil
    }
    private func refresh() {
        guard let player else { return }
        position = PlaybackTimeline.clamp(player.currentTime, duration: duration)
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.timer?.invalidate(); self.timer = nil; self.isPlaying = false
            if flag { self.position = self.duration }
            else { self.error = "Воспроизведение прервано" }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message = error?.localizedDescription ?? "Не удалось прочитать аудио"
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.pause(); self.error = message
        }
    }
}
