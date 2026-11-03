import SwiftUI
import UniformTypeIdentifiers
import CopilotCore

@MainActor private final class MaterialDropState: ObservableObject {
    @Published var targeted = false
}

struct MeetingMaterialsView: View {
    @ObservedObject var intelligence: LocalIntelligence
    @StateObject private var state = MaterialDropState()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { intelligence.importProposal() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down").font(.title2).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.string("Материалы встречи")).font(.callout.weight(.semibold))
                        Text(L10n.string("Перетащите документы сюда или нажмите, чтобы выбрать")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if intelligence.busyMaterials { ProgressView().controlSize(.small) }
                    else { Image(systemName: "plus.circle").foregroundStyle(.secondary) }
                }.padding(12).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(intelligence.busyMaterials)
            .background(Color.accentColor.opacity(state.targeted ? 0.14 : 0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(state.targeted ? 0.9 : 0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $state.targeted) { providers in
                guard !intelligence.busyMaterials else { return false }
                let targetMeeting = intelligence.snapshot?.session.id
                Task { @MainActor in
                    var urls: [URL] = []
                    for provider in providers {
                        let url: URL? = await withCheckedContinuation { continuation in
                            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                                let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                                continuation.resume(returning: url)
                            }
                        }
                        if let url { urls.append(url) }
                    }
                    guard intelligence.snapshot?.session.id == targetMeeting else { return }
                    if urls.count == providers.count { intelligence.importMaterials(urls) }
                    else { intelligence.error = L10n.string("Не удалось прочитать перетащенные файлы. Выберите их кнопкой.") }
                }
                return true
            }
            if !intelligence.record.supportMaterials.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(intelligence.record.supportMaterials) { material in
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                Text(material.name).lineLimit(1)
                                Button { intelligence.removeMaterial(material.id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).help(L10n.string("Убрать документ")).disabled(intelligence.busyMaterials)
                            }.font(.caption).padding(.horizontal, 9).padding(.vertical, 6)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            if !intelligence.error.isEmpty {
                Text(intelligence.error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }
}

struct LiveSalesHintView: View {
    @ObservedObject var intelligence: LocalIntelligence
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.string("Суфлёр"), systemImage: "sparkle").font(.callout.weight(.semibold))
                Spacer()
                if intelligence.busySuggestion { ProgressView().controlSize(.small) }
            }
            if !intelligence.clientUtterance.isEmpty {
                Text(intelligence.clientUtterance).font(.caption).foregroundStyle(.secondary).lineLimit(compact ? 3 : 2)
            }
            if !intelligence.suggestion.isEmpty {
                Text(L10n.string("Опора для ответа")).font(.caption.weight(.medium))
                Text(intelligence.suggestion).font(.callout).textSelection(.enabled).lineLimit(compact ? 7 : 4)
                if !intelligence.suggestionEvidence.isEmpty {
                    Text(intelligence.suggestionEvidence).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            } else if !intelligence.suggestionError.isEmpty {
                Text(intelligence.suggestionError).font(.caption).foregroundStyle(.orange).lineLimit(3)
            } else {
                Text(intelligence.record.proposalText.isEmpty && intelligence.record.dealText.isEmpty
                     ? L10n.string("Добавьте материалы или выберите сделку для автоматических подсказок.")
                     : L10n.string("Слушаю звук встречи. Подсказки появятся автоматически после распознавания реплик."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(compact ? 10 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}
