import AppKit
import Combine
import CopilotCore

@MainActor final class DealLaunchHandler {
    private let preparation = DealLaunchPreparation()
    private var revision: UInt64 = 0
    private var observations = Set<AnyCancellable>()
    private weak var observedModel: MeetingModel?

    private func observe(_ model: MeetingModel) {
        guard observedModel !== model else { return }
        observedModel = model; observations.removeAll()
        // Subscribe to meaningful transitions, not the model's half-second clock.
        let transitions = [model.$phase.map { _ in () }.eraseToAnyPublisher(),
            model.$current.map { _ in () }.eraseToAnyPublisher(),
            model.$title.map { _ in () }.eraseToAnyPublisher(),
            model.$processing.map { _ in () }.eraseToAnyPublisher(),
            model.$exporting.map { _ in () }.eraseToAnyPublisher(),
            model.$preparingPlayback.map { _ in () }.eraseToAnyPublisher(),
            model.$analyzingSpeakers.map { _ in () }.eraseToAnyPublisher(),
            model.intelligence.$busyMaterials.map { _ in () }.eraseToAnyPublisher(),
            model.intelligence.$busySummary.map { _ in () }.eraseToAnyPublisher(),
            model.intelligence.$busySuggestion.map { _ in () }.eraseToAnyPublisher(),
            model.intelligence.$busyChat.map { _ in () }.eraseToAnyPublisher(),
            model.updater.$isInstalling.map { _ in () }.eraseToAnyPublisher()]
        for publisher in transitions {
            publisher.dropFirst().sink { [weak self] in self?.revision &+= 1 }.store(in: &observations)
        }
        model.crm?.objectWillChange.sink { [weak self] in self?.revision &+= 1 }.store(in: &observations)
    }

    func open(_ url: URL, model: MeetingModel) async {
        do {
            let request = try DealLaunchRequest(url.absoluteString)
            observe(model)
            guard let crm = model.crm else { throw CopilotError.message(L10n.string("Хранилище CRM недоступно. Откройте приложение и проверьте настройки.")) }
            let result = try await preparation.prepare(request, state: {
                DealLaunchState(portal: crm.connected ? crm.connectedPortal : nil,
                                busy: model.updateBusy || model.locked, revision: self.revision)
            }, read: { request in
                let details = try await crm.previewDealForLaunch(request)
                return DealLaunchPreview(title: details.title, client: details.client)
            }, confirm: { preview in
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = L10n.string("Подготовить новую встречу по сделке?")
                alert.informativeText = L10n.format("Портал: %@\nСделка №%@: %@\nКлиент: %@\n\nТекущая запись останется в истории. Начало записи и сохранение в CRM выполняются отдельно.", String(describing: request.portal), String(describing: request.dealID), String(describing: preview.title), String(describing: preview.client.isEmpty ? L10n.string("не указан или недоступен") : preview.client))
                alert.addButton(withTitle: L10n.string("Подготовить встречу"))
                alert.addButton(withTitle: L10n.string("Отмена"))
                return alert.runModal() == .alertFirstButtonReturn
            }, apply: {
                // newMeeting clears the selected historical meeting; selectDeal must run
                // afterwards so its immutable journal binding can never be reassigned.
                model.newMeeting()
                var selectionRevision: UInt64?
                await crm.selectDeal(request.dealID, allowingCommit: {
                    // The first call occurs after selectDeal's own busy/context setup.
                    // Any subsequent transition, including a brief busy operation,
                    // prevents its asynchronous response from installing a context.
                    if selectionRevision == nil { selectionRevision = self.revision }
                    return self.revision == selectionRevision && !model.locked && !model.processing &&
                        crm.connected && crm.connectedPortal == request.portal
                })
                if let error = crm.error { model.error = error }
                else if crm.context?.dealID != request.dealID || crm.context?.portal != request.portal {
                    model.error = L10n.string("Подготовка отменена: состояние приложения изменилось. Откройте ссылку сделки ещё раз.")
                }
            })
            if case .stale = result { show(L10n.string("Состояние приложения или подключение изменилось. Откройте ссылку сделки ещё раз.")) }
        } catch { show(L10n.error(error)) }
    }

    private func show(_ message: String) {
        let alert = NSAlert(); alert.messageText = L10n.string("Не удалось подготовить встречу")
        alert.informativeText = message; alert.addButton(withTitle: L10n.string("ОК")); alert.runModal()
    }
}
