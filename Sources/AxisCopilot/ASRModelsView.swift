import SwiftUI
import CopilotCore

struct ASRModelsView: View {
    @ObservedObject var manager: ASRModelManager
    let busy: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Локальные модели речи")).font(.headline)
            Text(L10n.string("Аудио остаётся на этом Mac. Загрузка новой модели не меняет модель текущей встречи.")).font(.caption).foregroundStyle(.secondary)
            ForEach(manager.models) { model in
                HStack {
                    VStack(alignment: .leading) {
                        Text(model.name).fontWeight(manager.selectedID == model.id ? .semibold : .regular)
                        Text(L10n.format("Русский и английский · около %@ ГБ", String(describing: String(format: "%.1f", model.approximateGB)))).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if manager.installedPaths[model.id] != nil {
                        Button(manager.selectedID == model.id ? L10n.string("Выбрана") : L10n.string("Выбрать")) { manager.select(model, busy: busy) }.disabled(busy || manager.selectedID == model.id)
                    } else {
                        Button(L10n.string("Загрузить")) { manager.download(model) }.disabled(manager.downloadID != nil)
                    }
                    if manager.canRemove(model) {
                        Button(L10n.string("Удалить"), role: .destructive) { manager.remove(model, busy: busy) }.disabled(busy)
                    }
                }
            }
            if manager.canReuseParakeet && manager.installedPaths["parakeet-v3"] == nil {
                Button(L10n.string("Проверить установленную Parakeet")) { manager.reuseParakeet() }.disabled(manager.downloadID != nil)
            }
            Picker(L10n.string("Язык распознавания"), selection: $manager.language) {
                Text(L10n.string("Русский")).tag("ru"); Text("English").tag("en"); Text(L10n.string("Определять автоматически")).tag("auto")
            }.disabled(busy)
            if manager.selectedID == "parakeet-v3" { Text(L10n.string("Parakeet v3 определяет язык речи автоматически.")).font(.caption).foregroundStyle(.secondary) }
            if manager.downloadID != nil {
                HStack { ProgressView(value: manager.progress); Button(L10n.string("Отмена")) { manager.cancelDownload() } }
            }
            if !manager.status.isEmpty { Text(manager.status).font(.caption).foregroundStyle(.secondary) }
            if let error = manager.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
}
