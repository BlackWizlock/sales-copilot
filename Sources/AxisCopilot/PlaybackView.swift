import SwiftUI
import CopilotCore

@MainActor private final class PlaybackSliderState: ObservableObject {
    @Published var scrubbing: Bool = false
    @Published var proposed: Double = 0.0
    @Published var showVolume = false
}

struct PlaybackView: View {
    @StateObject private var viewState = PlaybackSliderState()
    @ObservedObject var playback: PlaybackController
    let busy: Bool
    let loading: Bool
    var hasEchoReduced: Bool = false
    let play: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button { playback.seek(to: playback.position - 10) } label: { Image(systemName: "gobackward.10") }.disabled(!playback.isLoaded || busy).help(L10n.string("Назад на 10 секунд"))
                Button(action: play) { Label(playback.isPlaying ? L10n.string("Пауза") : L10n.string("Слушать"), systemImage: playback.isPlaying ? "pause.fill" : "play.fill") }
                    .buttonStyle(.borderedProminent).disabled(busy || loading)
                Button { playback.seek(to: playback.position + 10) } label: { Image(systemName: "goforward.10") }.disabled(!playback.isLoaded || busy).help(L10n.string("Вперёд на 10 секунд"))
                if loading { ProgressView().controlSize(.small) }
                if hasEchoReduced {
                    Picker(L10n.string("Версия записи"), selection: $playback.preferEchoReduced) {
                        Text(L10n.string("Эхо снижено (копия)")).tag(true)
                        Text(L10n.string("Оригинал")).tag(false)
                    }.labelsHidden().pickerStyle(.menu).frame(maxWidth: 170)
                        .help(L10n.string("Версия записи")).disabled(busy || loading)
                }
                Text(PlaybackTimeline.time(playback.position)).font(.caption.monospaced()).foregroundStyle(.secondary)
            Slider(value: Binding(get: { viewState.scrubbing ? viewState.proposed : playback.position }, set: { viewState.proposed = $0; playback.seek(to: $0) }), in: 0...max(0.01, playback.duration), onEditingChanged: { editing in
                if editing { viewState.proposed = playback.position }
                viewState.scrubbing = editing
            }).disabled(!playback.isLoaded || busy).accessibilityLabel(L10n.string("Позиция записи"))
                Text(PlaybackTimeline.time(playback.duration)).font(.caption.monospaced()).foregroundStyle(.secondary)
                Picker(L10n.string("Скорость"), selection: $playback.rate) {
                    ForEach(PlaybackTimeline.rates, id: \.self) { value in Text(value.formatted(.number.locale(Locale(identifier: L10n.languageCode()))) + "×").tag(value) }
                }.fixedSize().help(L10n.string("Скорость без изменения высоты голоса"))
                Button { viewState.showVolume.toggle() } label: { Image(systemName: "speaker.wave.2") }.help(L10n.string("Громкость"))
                    .popover(isPresented: $viewState.showVolume) {
                        Slider(value: $playback.volume, in: 0...1).frame(width: 150).padding().accessibilityLabel(L10n.string("Громкость"))
                    }
            }
            if let error = playback.error { Text(error).foregroundStyle(.orange).font(.caption) }
        }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}
