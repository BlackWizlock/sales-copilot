import SwiftUI

struct LocalIntelligenceSettingsView: View {
    @ObservedObject private var runtime = IntelligenceRuntime.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("Локальный ИИ")).font(.headline)
            Text(L10n.string("Модель для итогов, подсказок и вопросов по встрече работает на этом Mac. Первая загрузка требует интернета и около 4,7 ГБ.")).font(.caption).foregroundStyle(.secondary)
            Button(runtime.preparing ? L10n.string("Подготовка…") : L10n.string("Подготовить локальный ИИ")) { Task { await runtime.prepare() } }.disabled(runtime.preparing)
            if !runtime.availableModels.isEmpty {
                Picker(L10n.string("Локальная языковая модель"), selection: $runtime.selectedModel) {
                    ForEach(runtime.availableModels, id: \.self) { Text($0).tag($0) }
                }
            }
            Text(runtime.status).font(.caption).textSelection(.enabled)
        }
    }
}
