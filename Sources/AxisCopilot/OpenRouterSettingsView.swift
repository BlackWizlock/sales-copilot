import SwiftUI

struct OpenRouterSettingsView: View {
    @ObservedObject private var sandbox = OpenRouterSandbox.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OpenRouter").font(.headline)
            Text(L10n.string("Выбранная модель готовит резюме, отвечает в чате и подсказывает во время встречи. Распознавание речи работает на Mac.")).font(.caption)
            Toggle(L10n.string("Использовать OpenRouter для резюме, чата и подсказок"), isOn: $sandbox.meetingsEnabled)
            Text(L10n.string("При включении текст встречи, выбранные материалы и контекст сделки передаются OpenRouter и поставщику модели. Используйте только данные, которые разрешено отправлять. Аудио не отправляется. Оплата по вашему ключу, в пределах дневного бюджета.")).font(.caption).foregroundStyle(.secondary)
            SecureField(L10n.string("Личный ключ OpenRouter"), text: $sandbox.keyInput)
            HStack {
                Button(L10n.string("Сохранить ключ")) { Task { await sandbox.saveKey() } }.disabled(sandbox.keyInput.isEmpty)
                if !sandbox.hasKey { Button(L10n.string("Проверить сохранённый ключ")) { Task { await sandbox.unlockKey() } } }
                Button(L10n.string("Проверить ключ")) { Task { await sandbox.checkKey() } }.disabled(!sandbox.hasKey)
                Button(L10n.string("Отключить ключ")) { Task { await sandbox.removeKey() } }.disabled(!sandbox.hasKey)
            }.disabled(sandbox.keyBusy)
            Button(L10n.string("Загрузить каталог моделей и цены")) { Task { await sandbox.loadModels() } }
            if !sandbox.models.isEmpty {
                Picker(L10n.string("Облачная модель"), selection: $sandbox.selectedModel) {
                    Text(L10n.string("Выберите модель")).tag("")
                    ForEach(sandbox.meetingModels) { model in Text(model.name).tag(model.id) }
                }
                Text(sandbox.selectedModelPriceDescription).font(.caption).textSelection(.enabled)
            }
            Text(L10n.string("Дневной предел в USD (по умолчанию 0)")).font(.caption)
            TextField(L10n.string("Дневной предел в USD (по умолчанию 0)"), text: $sandbox.budgetText)
            Text(L10n.format("Учтено за день UTC: $%@. Резюме может включать несколько запросов. При неизвестной стоимости резерв сохраняется.", sandbox.chargedText)).font(.caption)
            DisclosureGroup(L10n.string("Проверка на тестовом вопросе")) {
                Toggle(L10n.string("Включить облачную песочницу"), isOn: $sandbox.enabled)
                if sandbox.enabled {
                Text(L10n.format("Максимальная оценка тестового запроса: $%@", sandbox.estimateText)).font(.caption)
                Text(L10n.string("Синтетический или публичный тестовый вопрос")).font(.subheadline)
                TextEditor(text: $sandbox.prompt).frame(minHeight: 80, maxHeight: 150)
                Toggle(L10n.string("Подтверждаю, что здесь только синтетические или публичные данные без клиентских и персональных сведений"), isOn: $sandbox.attested)
                HStack {
                    Button(L10n.string("Отправить платный тестовый запрос")) { sandbox.send() }.disabled(sandbox.busy || !sandbox.attested || !sandbox.hasKey)
                    if sandbox.busy { ProgressView().controlSize(.small); Button(L10n.string("Отменить запрос")) { sandbox.cancel() } }
                }
            }
            }
            if !sandbox.reply.isEmpty { Text(sandbox.reply).textSelection(.enabled) }
            if !sandbox.actualModel.isEmpty { Text(sandbox.actualModel).font(.caption) }
            if !sandbox.status.isEmpty { Text(sandbox.status).font(.caption).textSelection(.enabled) }
        }
        .task { await sandbox.loadSavedKey() }
        .onChange(of: sandbox.prompt) { _, _ in sandbox.contextChanged() }
        .onChange(of: sandbox.selectedModel) { _, _ in sandbox.contextChanged() }
        .onChange(of: sandbox.enabled) { _, enabled in if !enabled { sandbox.cancel() } }
        .onDisappear { sandbox.keyInput = "" }
    }
}
