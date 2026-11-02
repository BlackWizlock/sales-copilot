import SwiftUI
import CopilotCore

@MainActor private final class SpeakerPanelState: ObservableObject {
    @Published var editing: String? = nil
    @Published var name: String = ""
}

struct SpeakerPanel: View {
    @StateObject private var viewState = SpeakerPanelState()
    @ObservedObject var model: MeetingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Участники").font(.headline)
                Spacer()
                if model.analyzingSpeakers { ProgressView().controlSize(.small) }
                else { Button("Разделить голоса") { model.analyzeSpeakers() }.disabled(model.locked || model.current?.chunks.isEmpty != false) }
            }
            Text(model.speakerStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let speakers = model.current?.speakers, !speakers.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(speakers) { speaker in
                            Button(speaker.name, systemImage: "person.crop.circle") { viewState.editing = speaker.id; viewState.name = speaker.name }
                                .disabled(model.analyzingSpeakers || model.phase != .idle)
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: Binding(get: { viewState.editing != nil }, set: { if !$0 { viewState.editing = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Имя участника").font(.title2)
                Text("Имя применяется к этому голосу только в выбранной встрече. Конкретную фразу можно переназначить через её подпись.").foregroundStyle(.secondary)
                TextField("Имя", text: $viewState.name).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Отмена") { viewState.editing = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Сохранить") { if let id = viewState.editing { model.renameSpeaker(id, name: viewState.name) }; viewState.editing = nil }.keyboardShortcut(.defaultAction)
                        .disabled(viewState.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 440)
        }
    }
}
