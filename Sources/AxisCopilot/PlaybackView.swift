import SwiftUI
import CopilotCore

@MainActor private final class PlaybackSliderState: ObservableObject {
    @Published var scrubbing: Bool = false
    @Published var proposed: Double = 0.0
}

struct PlaybackView: View {
    @StateObject private var viewState = PlaybackSliderState()
    @ObservedObject var playback: PlaybackController
    let busy: Bool
    let loading: Bool
    let play: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(get: { viewState.scrubbing ? viewState.proposed : playback.position }, set: { viewState.proposed = $0; playback.seek(to: $0) }), in: 0...max(0.01, playback.duration), onEditingChanged: { editing in
                if editing { viewState.proposed = playback.position }
                viewState.scrubbing = editing
            }).disabled(!playback.isLoaded || busy).accessibilityLabel("Позиция записи")
            HStack {
                Text(PlaybackTimeline.time(playback.position))
                Spacer()
                Text(PlaybackTimeline.time(playback.duration))
            }.font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { playback.seek(to: playback.position - 10) } label: { Image(systemName: "gobackward.10") }.disabled(!playback.isLoaded || busy).help("Назад на 10 секунд")
                Button(action: play) { Label(playback.isPlaying ? "Пауза" : "Слушать", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") }
                    .buttonStyle(.borderedProminent).disabled(busy || loading)
                    .keyboardShortcut(.space, modifiers: [])
                Button { playback.seek(to: playback.position + 10) } label: { Image(systemName: "goforward.10") }.disabled(!playback.isLoaded || busy).help("Вперёд на 10 секунд")
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Picker("Скорость", selection: $playback.rate) {
                    ForEach(PlaybackTimeline.rates, id: \.self) { value in Text(value.formatted(.number.locale(Locale(identifier: "ru_RU"))) + "×").tag(value) }
                }.fixedSize().help("Скорость без изменения высоты голоса")
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: $playback.volume, in: 0...1).frame(width: 70).accessibilityLabel("Громкость")
            }
            if let error = playback.error { Text(error).foregroundStyle(.orange).font(.caption) }
        }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}
