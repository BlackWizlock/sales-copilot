import SwiftUI
import CopilotCore

@MainActor private final class TranscriptViewState: ObservableObject {
    @Published var query: String = ""
    @Published var following: Bool = true
    @Published var lastFollowed: UUID? = nil
}

struct TranscriptPanel: View {
    @StateObject private var viewState = TranscriptViewState()
    @ObservedObject var model: MeetingModel
    @ObservedObject var playback: PlaybackController
    private var lines: [TranscriptLine] { model.current?.transcript ?? [] }
    private var visible: [TranscriptLine] { viewState.query.isEmpty ? lines : lines.filter { $0.text.localizedCaseInsensitiveContains(viewState.query) } }
    private var active: [UUID] { PlaybackTimeline.activeLines(lines, at: playback.position) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Транскрипция").font(.title2.weight(.medium))
                Spacer()
                TextField("Найти в тексте", text: $viewState.query).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                Toggle("Следовать", isOn: $viewState.following).toggleStyle(.checkbox).font(.caption)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if lines.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Здесь появится текст разговора").font(.headline)
                                Text("Фразы обрабатываются после накопления 8 секунд звука. После завершения записи обработка продолжается.").foregroundStyle(.secondary)
                            }.padding(.vertical, 28)
                        } else if visible.isEmpty {
                            Text("Совпадений нет").foregroundStyle(.secondary).padding(.vertical, 28)
                        }
                        ForEach(visible) { line in
                            HStack(alignment: .top, spacing: 14) {
                                Button(PlaybackTimeline.time(line.start)) { model.play(line) }
                                    .disabled(model.phase != .idle || model.preparingPlayback || model.exporting)
                                    .buttonStyle(.plain).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 52)
                                    .help("Воспроизвести с этой фразы")
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Menu {
                                            ForEach(model.current?.speakers ?? []) { speaker in
                                                Button(speaker.name) { model.assignSpeaker(speaker.id, to: line.id) }
                                            }
                                            Button("Не определён") { model.assignSpeaker(nil, to: line.id) }
                                        } label: { Text(speakerName(line)).font(.caption.weight(.semibold)).foregroundStyle(AxisBrand.teal) }
                                            .menuStyle(.borderlessButton).fixedSize().disabled(model.phase != .idle || model.analyzingSpeakers)
                                        Text(line.source.title).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(12)
                                .background(active.contains(line.id) && playback.isLoaded ? AxisBrand.teal.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle()).onTapGesture { model.play(line) }.id(line.id)
                        }
                    }
                }
                .onScrollPhaseChange { _, phase in if phase == .interacting { viewState.following = false } }
                .onChange(of: playback.position) { _, _ in
                    guard viewState.following, viewState.query.isEmpty, let id = active.first, viewState.lastFollowed != id else { return }
                    viewState.lastFollowed = id
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: lines.count) { _, _ in
                    if viewState.following, viewState.query.isEmpty, model.phase == .recording, let id = lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: viewState.following) { _, follow in
                    if follow, let id = model.phase == .recording ? lines.last?.id : active.first { proxy.scrollTo(id, anchor: .center); viewState.lastFollowed = id }
                }
                .onChange(of: model.current?.id) { _, _ in viewState.query = ""; viewState.following = true; viewState.lastFollowed = nil }
            }
            if !viewState.following {
                Button("К текущей фразе", systemImage: "text.line.last.and.arrowtriangle.forward") { viewState.following = true }.font(.caption)
            }
        }
    }
    private func speakerName(_ line: TranscriptLine) -> String {
        guard let current = model.current, let id = current.speakerID(for: line),
              let profile = current.speakers?.first(where: { $0.id == id }) else {
            return model.current?.speakerTurns == nil ? "Голос не определён" : "Неуверенное назначение"
        }
        return profile.name
    }
}
