import SwiftUI
import CopilotCore

@MainActor private final class CRMPanelState: ObservableObject {
    @Published var search = ""
    @Published var includeAudio = true
    @Published var preparing = false
    @Published var preparationError: String?
}

struct CRMPanel: View {
    @ObservedObject var controller: CRMController
    var session: MeetingSession?
    var summaryText: String
    var audioURL: URL?
    var prepareAudio: () async throws -> URL
    var onContextChanged: (String) -> Void = { _ in }
    @StateObject private var ui = CRMPanelState()
    private var selected: DealContext? {
        if let session { return controller.context(for: session.id) }
        return controller.context
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.string("Сделка Битрикс24")).font(.title2.bold())
                selectedDeal
                if controller.connected {
                    dealSelection
                    DisclosureGroup(L10n.string("Подключение к Битрикс24")) {
                        BitrixConnectionSettingsView(controller: controller).padding(.top, 8)
                    }
                } else {
                    Text(L10n.string("Для выбора сделки подключите личный вебхук своего портала. Подключение настраивается здесь или в «Настройки» → «Битрикс24». Ключ другой интеграции автоматически не используется."))
                        .font(.callout).foregroundStyle(.secondary)
                    BitrixConnectionSettingsView(controller: controller)
                }
                if let error = controller.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if controller.busy { ProgressView(L10n.string("Обращение к Битрикс24…")) }
                if let context = selected {
                    if let session {
                        Divider()
                        Text(L10n.string("Сохранить результат встречи")).font(.headline)
                        Text(L10n.format("Итоги и транскрипция попадут в сделку №%@ «%@» после вашего подтверждения.", String(describing: context.dealID), String(describing: context.title)))
                            .font(.callout)
                        Toggle(L10n.string("Приложить запись M4A"), isOn: $ui.includeAudio).disabled(ui.preparing)
                        if ui.preparing { ProgressView(L10n.string("Подготовка записи…")) }
                        if let error = ui.preparationError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                        Text(L10n.string("Сохраняется обычное завершённое дело «Встреча» с итогами и транскрипцией. Анализ записи внутри Битрикс24 не подтверждён.")).font(.caption).foregroundStyle(.secondary)
                        Button(L10n.string("Сохранить встречу в эту сделку…")) {
                            ui.preparationError = nil
                            ui.preparing = true
                            let includeAudio = ui.includeAudio
                            Task {
                                defer { ui.preparing = false }
                                do {
                                    let preparedAudio = includeAudio ? try await prepareAudio() : nil
                                    guard self.session?.id == session.id else { return }
                                    controller.prepareExport(session: session, summary: summaryText, audioURL: preparedAudio)
                                } catch { ui.preparationError = L10n.error(error) }
                            }
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(controller.busy || ui.preparing || !controller.connected || session.state == .recording || session.state == .processing)
                    }
                    DisclosureGroup(L10n.string("Контекст сделки и все поля")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(context.asPlainText).font(.callout).textSelection(.enabled)
                            Text(context.fields.keys.sorted().map { "\($0): \(context.fields[$0]!.text)" }.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                            Text(L10n.string("Форма полей\n") + context.fieldConfiguration.text).font(.caption.monospaced()).textSelection(.enabled)
                        }.padding(.top, 8)
                    }
                }
                if let operation = controller.exportOperation {
                    if operation.state == .completed {
                        Text(L10n.format("Сохранено. Дело №%@", String(describing: operation.activityID ?? ""))).foregroundStyle(.green)
                        if let url = operation.resultURL { Link(L10n.string("Открыть результат в сделке"), destination: url) }
                    } else if operation.state == .needsReconciliation || operation.state == .sending {
                        Text(L10n.string("Исход отправки неизвестен. Повторное дело не создаётся."))
                        Button(L10n.string("Сверить результат")) { Task { await controller.reconcile(meetingID: operation.preview.meetingID) } }.disabled(controller.busy)
                    }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            controller.activate(session: session)
            await controller.restoreConnection()
            if controller.connected && controller.deals.isEmpty { await controller.search("") }
        }
        .onChange(of: session?.id) { _, _ in controller.activate(session: session) }
        .onChange(of: controller.context) { _, context in onContextChanged(context?.asPlainText ?? "") }
        .onChange(of: controller.connected) { _, connected in
            if connected && controller.deals.isEmpty { Task { await controller.search("") } }
        }
        .sheet(isPresented: Binding(get: { controller.preview != nil }, set: { if !$0 { controller.cancelPreview() } })) {
            if let preview = controller.preview { exportPreview(preview) }
        }
    }
    private var selectedDeal: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let context = selected {
                Label(session == nil ? L10n.string("Выбрана для новой встречи") : L10n.string("Эта встреча привязана к сделке"), systemImage: "link")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("№\(context.dealID) · \(context.title)").font(.title3.bold()).textSelection(.enabled)
                if !context.client.isEmpty { Text(context.client).font(.callout) }
                HStack {
                    Link(L10n.string("Открыть в Битрикс24"), destination: context.url)
                    Text(context.portal).foregroundStyle(.secondary)
                }.font(.callout)
                Text(session == nil ? L10n.string("При начале записи эта сделка сохранится вместе со встречей.") : L10n.string("Привязка сохранена на этом Mac и восстановится при открытии записи."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label(L10n.string("Сделка пока не выбрана"), systemImage: "link.badge.plus").font(.headline)
                Text(session == nil ? L10n.string("Выберите сделку перед записью, чтобы сохранить её контекст во встрече.") : L10n.string("Найдите сделку ниже и нажмите на неё, чтобы привязать эту встречу."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.25)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private var dealSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if selected == nil || session == nil {
                Text(selected == nil ? L10n.string("Выбрать сделку") : L10n.string("Выбрать другую сделку")).font(.headline)
            HStack {
                TextField(L10n.string("Введите название сделки"), text: $ui.search).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await controller.search(ui.search) } }
                Button(L10n.string("Найти сделки")) { Task { await controller.search(ui.search) } }.disabled(controller.busy)
            }
            ForEach(controller.deals) { deal in
                Button {
                    Task { await controller.selectDeal(deal.id) }
                } label: {
                    HStack {
                        Text("№\(deal.id) · \(deal.title)").lineLimit(2)
                        Spacer()
                        if selected?.dealID == deal.id { Image(systemName: "checkmark.circle.fill") }
                        else { Text(L10n.string("Выбрать")).font(.caption) }
                    }.padding(.vertical, 7).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(controller.busy)
            }
            }
            if let context = selected {
                if session != nil { Text(L10n.string("Для другой сделки начните новую встречу. Привязку этой записи приложение сохраняет.")).font(.caption).foregroundStyle(.secondary) }
                Button(L10n.format("Обновить снимок сделки №%@", String(describing: context.dealID))) { Task { await controller.selectDeal(context.dealID) } }.disabled(controller.busy)
            }
        }
    }
    private func exportPreview(_ preview: CRMExportPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Сохранение встречи в Битрикс24")).font(.title2.bold())
            Text(L10n.format("%@\nСделка №%@ · %@", String(describing: preview.portal), String(describing: preview.dealID), String(describing: preview.dealTitle))).textSelection(.enabled)
            Text("\(preview.title) · \(preview.started.formatted())")
            Text(L10n.format("Вложения: transcript.txt (%@ байт)", String(describing: Data(preview.transcript.utf8).count)) + (preview.audioName.map { L10n.format(", %@ (%@ байт)", String(describing: $0), String(describing: preview.audioBytes)) } ?? L10n.string(". Аудио не отправляется.")))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(preview.summary).textSelection(.enabled)
                    Divider()
                    Text(preview.transcript).font(.caption).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(L10n.string("Создаст завершённое дело «Встреча». Поля и стадия сделки не изменяются. Встроенный анализ Битрикс24 не запускается.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.string("Отмена")) { controller.cancelPreview() }
                Spacer()
                Button(L10n.string("Сохранить в выбранную сделку")) {
                    guard let session else { return }
                    Task { await controller.confirmExport(session: session, summary: summaryText, audioURL: ui.includeAudio ? audioURL : nil) }
                }.disabled(controller.busy)
            }
        }.padding(24).frame(width: 680, height: 620)
    }
}

@MainActor private final class BitrixConnectionState: ObservableObject {
    @Published var webhook = ""
}

/// Shared by internal Settings and the meeting CRM tab. Never displays a saved webhook or secret.
struct BitrixConnectionSettingsView: View {
    @ObservedObject var controller: CRMController
    @StateObject private var ui = BitrixConnectionState()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Битрикс24")).font(.headline)
            if let portal = controller.connectedPortal {
                Text(L10n.format("Подключён портал: %@", String(describing: portal))).font(.callout).textSelection(.enabled)
            }
            Text(controller.status).font(.callout).textSelection(.enabled)
            Text(L10n.string("В настройках входящего вебхука своего портала отметьте следующие права.")).font(.callout)
            VStack(alignment: .leading, spacing: 5) {
                Text("CRM · crm").font(.callout.bold())
                Text(L10n.string("Чтение сделок, компаний, контактов и дел; создание дела встречи только после подтверждения.")).font(.caption).foregroundStyle(.secondary)
                Text(L10n.string("Диск · disk")).font(.callout.bold())
                Text(L10n.string("Скачивание вложений созданного дела для проверки сохранности транскрипции и аудио.")).font(.caption).foregroundStyle(.secondary)
                Text(L10n.string("Календарь · calendar")).font(.callout.bold())
                Text(L10n.string("Чтение событий вашего календаря и ссылок на встречи.")).font(.caption).foregroundStyle(.secondary)
                Text(L10n.string("Пользователи (минимально) · user_brief")).font(.callout.bold())
                Text(L10n.string("Определение вашего пользователя через user.current. Уже выданные user_basic или user также подходят; расширенные права не требуются.")).font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.string("Права вебхука не заменяют ваши права на карточки и календарь. Проверка подключения читает user.current и scope; доступ к выбранной сделке проверяется при её загрузке.")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.string("Вебхук Битрикс24")).font(.callout.bold())
            HStack {
                SecureField(L10n.string("Вставьте личный вебхук"), text: $ui.webhook)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.string("Вебхук Битрикс24"))
                Button(L10n.string("Очистить поле")) { ui.webhook = "" }
                    .disabled(ui.webhook.isEmpty)
                    .help(L10n.string("Удаляет только введённый текст. Сохранённое подключение останется."))
            }
            Text(L10n.string("Формат адреса: https://ваш-портал.bitrix24.ru/rest/номер-пользователя/ключ/")).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(L10n.string("Поле всегда открывается пустым. Сохранённый ключ сюда не подставляется. Введённый текст можно выделить ⌘A и удалить либо очистить кнопкой. Ключ хранится только в Связке ключей этого Mac.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(controller.connected ? L10n.string("Сохранить новое подключение") : L10n.string("Сохранить и подключить")) {
                    let value = ui.webhook; ui.webhook = ""
                    Task { await controller.connect(webhook: value) }
                }.disabled(ui.webhook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.busy)
                Button(controller.connected ? L10n.string("Проверить подключение") : L10n.string("Проверить сохранённое подключение")) { Task { await controller.checkConnection() } }
                    .disabled(controller.busy)
                Button(L10n.string("Отключить подключение")) { ui.webhook = ""; Task { await controller.disconnect() } }
                    .disabled(!controller.connected || controller.busy)
                    .help(L10n.string("Отключает Битрикс24 и удаляет сохранённый ключ из Связки ключей этого Mac."))
            }
            if let error = controller.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if controller.busy { ProgressView(L10n.string("Проверка подключения…")) }
        }
        .task { await controller.restoreConnection() }
        .onDisappear { ui.webhook = "" }
    }
}

/// Always-visible entry to deal selection; the parent owns the destination sheet.
struct DealBindingButton: View {
    @ObservedObject var controller: CRMController
    var session: MeetingSession?
    var onOpen: () -> Void
    private var selected: DealContext? {
        if let session { return controller.context(for: session.id) }
        return controller.context
    }
    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image(systemName: selected == nil ? "link.badge.plus" : "link")
                if let selected {
                    Text(L10n.format("Сделка №%@ · %@", String(describing: selected.dealID), String(describing: selected.title))).lineLimit(1).truncationMode(.tail)
                    if !controller.connected { Text(L10n.string("офлайн")).font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text(controller.connected ? L10n.string("Выбрать сделку") : L10n.string("Сделка · подключить Битрикс24")).lineLimit(1)
                }
            }.frame(maxWidth: 330)
        }
        .help(selected.map { "\($0.portal) · №\($0.dealID) · \($0.title)" } ?? L10n.string("Выбрать сделку для этой встречи и открыть её контекст"))
        .accessibilityLabel(selected.map { L10n.format("Сделка №%@, %@. Открыть привязку встречи", String(describing: $0.dealID), String(describing: $0.title)) } ?? L10n.string("Выбрать сделку Битрикс24"))
    }
}
