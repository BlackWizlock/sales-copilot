import Foundation
import SwiftUI
import AppKit
import CopilotCore

@MainActor final class CRMController: ObservableObject {
    @Published private(set) var context: DealContext?
    @Published private(set) var deals: [BitrixDealChoice] = []
    @Published private(set) var meetings: [CalendarMeeting] = []
    @Published private(set) var calendarDeals: [String: CalendarDealDetails] = [:]
    @Published private(set) var calendarDealErrors: [String: String] = [:]
    @Published private(set) var savingCalendar = false
    @Published private(set) var status = L10n.string("Битрикс24 не подключён")
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var connected = false
    @Published private(set) var connectedPortal: String?
    @Published private(set) var preview: CRMExportPreview?
    @Published private(set) var exportOperation: CRMExport?
    private var client: BitrixClient?
    private var ownerID = ""
    private var activeMeetingID: UUID?
    private var generation = UUID()
    private var journal: CRMJournal?
    init(store: SessionStore, client: BitrixClient? = nil, ownerID: String = "") {
        self.client = client; self.ownerID = ownerID; self.connected = client != nil
        do { journal = try CRMJournal(root: store.root.appendingPathComponent("crm", isDirectory: true)) }
        catch { self.error = L10n.error(error) }
    }
    func context(for meetingID: UUID) -> DealContext? {
        do { return try journal?.context(meetingID: meetingID) }
        catch { self.error = L10n.error(error); return nil }
    }
    func activate(session: MeetingSession?, isNew: Bool = false) {
        guard activeMeetingID != session?.id || isNew else { return }
        let selected = context
        generation = UUID(); activeMeetingID = session?.id; preview = nil; exportOperation = nil; error = nil
        guard let session else { context = nil; return }
        do {
            if let saved = try journal?.context(meetingID: session.id) { context = saved }
            else if isNew, session.state == .recording, let selected {
                try requireJournal().bind(selected, meetingID: session.id); context = selected
            } else { context = nil }
            exportOperation = try journal?.operation(meetingID: session.id)
        } catch { self.error = L10n.error(error); context = nil }
    }
    func restoreConnection(allowInteraction: Bool = false) async {
        guard client == nil, !busy else { return }
        busy = true; defer { busy = false }
        do {
            guard let credentials = try await KeychainAccess.offMain({ try BitrixCredentials.load(allowInteraction: allowInteraction) }) else { return }
            try await connect(credentials, alreadyBusy: true)
        } catch { self.error = L10n.error(error); status = L10n.string("Подключение не проверено") }
    }
    func checkConnection() async {
        guard !busy else { return }
        guard let client else { await restoreConnection(); return }
        busy = true; defer { busy = false }
        do { let result = try await client.checkConnection(); ownerID = result.userID; status = result.message; error = nil }
        catch { self.error = L10n.error(error) }
    }
    func connect(webhook: String) async {
        guard !busy else { return }
        do {
            let credentials = try BitrixCredentials(webhook: webhook)
            try await connect(credentials)
            busy = true
            defer { busy = false }
            try await KeychainAccess.offMain { try credentials.save() }
        } catch { self.error = L10n.error(error) }
    }
    private func connect(_ credentials: BitrixCredentials, alreadyBusy: Bool = false) async throws {
        guard alreadyBusy || !busy else { throw CopilotError.message(L10n.string("Дождитесь текущего обращения к Битрикс24")) }
        busy = true; defer { busy = false }
        let candidate = BitrixClient(credentials: credentials)
        let checked = try await candidate.checkConnection()
        if connectedPortal != credentials.portal {
            deals = []; meetings = []; preview = nil; calendarDeals = [:]; calendarDealErrors = [:]
            if activeMeetingID == nil { context = nil }
        }
        client = candidate; ownerID = checked.userID; connected = true; connectedPortal = credentials.portal; status = checked.message; error = nil
    }
    func disconnect() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { try await KeychainAccess.offMain { try BitrixCredentials.remove() }; client = nil; connected = false; connectedPortal = nil; preview = nil; generation = UUID(); status = L10n.string("Подключение отключено на этом Mac"); deals = []; meetings = []; calendarDeals = [:]; calendarDealErrors = [:] }
        catch { self.error = L10n.error(error) }
    }
    func search(_ text: String) async {
        guard let client else { error = L10n.string("Сначала подключите Битрикс24"); return }
        busy = true; defer { busy = false }
        do { deals = try await client.searchDeals(text); error = nil }
        catch { self.error = L10n.error(error) }
    }
    func refreshCalendar(from: Date? = nil, to: Date? = nil) async {
        guard !busy else { return }
        guard let client else { error = L10n.string("Сначала подключите Битрикс24"); return }
        busy = true; defer { busy = false }
        do {
            if let from, let to {
                meetings = try await client.calendar(ownerID: ownerID, from: from, to: to)
            } else {
                meetings = try await client.calendar(ownerID: ownerID).filter { ($0.ends ?? $0.starts.addingTimeInterval(3600)) >= Date() }
            }
            error = nil
        }
        catch { self.error = L10n.error(error) }
    }
    /// Read-only preview. It does not change selected context, preview or history.
    func previewDealForLaunch(_ request: DealLaunchRequest) async throws -> CalendarDealDetails {
        guard !busy, connected, connectedPortal == request.portal, let client else {
            throw CopilotError.message(L10n.string("Подключите исходный портал и дождитесь текущего обращения к Битрикс24."))
        }
        let details = try await client.calendarDeal(request.dealID)
        guard !Task.isCancelled, self.client === client, connectedPortal == request.portal else {
            throw CopilotError.message(L10n.string("Подключение изменилось. Откройте ссылку сделки ещё раз."))
        }
        return details
    }
    func selectDeal(_ id: String, allowingCommit: () -> Bool = { true }) async {
        guard let client else { error = L10n.string("Сначала подключите Битрикс24"); return }
        if let meetingID = activeMeetingID, let bound = context(for: meetingID), bound.dealID != id {
            error = L10n.format("У этой записи уже сделка №%@. Для другой сделки создайте новую встречу.", String(describing: bound.dealID)); return
        }
        let request = UUID(); generation = request
        let meetingID = activeMeetingID
        context = nil; preview = nil; busy = true
        defer { busy = false }
        guard allowingCommit() else { return }
        do {
            let value = try await client.loadDeal(id: id, calendarOwner: ownerID)
            guard !Task.isCancelled, self.client === client, generation == request, activeMeetingID == meetingID, allowingCommit() else { return }
            if let meetingID { try requireJournal().bind(value, meetingID: meetingID) }
            context = value; error = nil
        } catch { if generation == request { self.error = L10n.error(error) } }
    }
    func loadCalendarDeals(_ ids: [String]) async {
        guard let client else { return }
        for id in Set(ids).sorted() where calendarDeals[id] == nil {
            guard !Task.isCancelled else { return }
            do {
                let value = try await client.calendarDeal(id)
                guard !Task.isCancelled, self.client === client else { return }
                calendarDeals[id] = value; calendarDealErrors[id] = nil
            } catch {
                guard !Task.isCancelled, self.client === client else { return }
                calendarDealErrors[id] = L10n.error(error)
            }
        }
    }
    func saveCalendarDescription(_ event: CalendarMeeting, description: String) async throws {
        guard let client, !busy, !savingCalendar else { throw CopilotError.message(L10n.string("Дождитесь подключения Битрикс24 или текущего обращения")) }
        savingCalendar = true; busy = true
        defer { savingCalendar = false; busy = false }
        do {
            try await client.updateCalendarDescription(event, description: description, ownerID: ownerID)
            guard self.client === client else { throw CopilotError.message(L10n.string("Подключение изменилось. Обновите календарь исходного портала.")) }
            // Read back the occurrence rather than pretending the submitted text is the server result.
            let values = try await client.calendar(ownerID: ownerID, from: event.starts.addingTimeInterval(-86400), to: event.starts.addingTimeInterval(86400))
            let candidates = values.filter { $0.starts == event.starts && ($0.id == event.id || $0.raw["RECURRENCE_ID"]?.text == event.id || $0.raw["PARENT_ID"]?.text == event.id) }
            guard let confirmed = candidates.first(where: { $0.raw["DESCRIPTION"]?.text == description }) else {
                throw CopilotError.message(L10n.string("Запрос принят, но сохранённое описание ещё не подтверждено. Обновите календарь перед повтором; текст сохранён в редакторе."))
            }
            meetings.removeAll { $0.occurrenceID == event.occurrenceID }
            meetings.append(confirmed); meetings.sort { $0.starts < $1.starts }
        } catch {
            throw CopilotError.message(L10n.error(error) + L10n.string(" Повторная отправка автоматически не выполняется."))
        }
    }
    func join(_ event: CalendarMeeting) {
        guard let raw = event.joinURL, let url = MeetingLink.validated(raw.absoluteString) else { error = L10n.string("В событии нет разрешённой ссылки Телемост или Zoom"); return }
        if !NSWorkspace.shared.open(url) { error = L10n.string("Не удалось открыть ссылку встречи") }
    }
    func prepareExport(session: MeetingSession, summary: String, audioURL: URL?) {
        guard activeMeetingID == session.id else { return }
        do {
            guard let context = context(for: session.id) else { throw CopilotError.message(L10n.string("Сначала выберите и привяжите сделку")) }
            guard let client else { throw CopilotError.message(L10n.string("Битрикс24 не подключён")) }; _ = client
            _ = try BitrixClient.meetingCommunication(context)
            let p = try CRMExportPreview(session: session, context: context, summary: summary, audioURL: audioURL)
            if let old = try requireJournal().operation(meetingID: session.id), old.state == .completed || old.state == .needsReconciliation {
                exportOperation = old; preview = nil
                error = old.state == .completed ? L10n.string("Эта встреча уже сохранена. Повторное дело не создаётся.") : L10n.string("Исход прежней отправки неизвестен. Нажмите «Сверить результат».")
                return
            }
            preview = p; error = nil
        } catch { self.error = L10n.error(error) }
    }
    func cancelPreview() { preview = nil }
    func confirmExport(session: MeetingSession, summary: String, audioURL: URL?) async {
        guard !busy, activeMeetingID == session.id, let client, let p = preview else { return }
        let requestGeneration = generation
        func isCurrent() -> Bool { activeMeetingID == session.id && generation == requestGeneration }
        do {
            guard try p.matches(session: session, summary: summary, audioURL: audioURL), let bound = context(for: session.id), bound.dealID == p.dealID else { throw CopilotError.message(L10n.string("Встреча изменилась. Откройте предварительный просмотр заново.")) }
            _ = try BitrixClient.meetingCommunication(bound)
            let journal = try requireJournal()
            if let old = try journal.operation(meetingID: session.id), old.state == .completed || old.state == .needsReconciliation { exportOperation = old; preview = nil; throw CopilotError.message(L10n.string("Повторная отправка запрещена. Сначала сверьте результат.")) }
            busy = true; defer { busy = false }
            try await client.validateExportAccess()
            guard isCurrent() else { return }
            var operation = CRMExport(preview: p)
            try journal.save(operation) // Persist intent before any potentially mutating network call.
            if let existing = try await client.findExport(operation) {
                operation.activityID = existing; operation.state = .needsReconciliation; try journal.save(operation)
                try await client.verifyExport(operation, activityID: existing)
                operation.state = .completed; try journal.save(operation)
                if isCurrent() { exportOperation = operation; preview = nil; error = nil }
                return
            }
            let audio = try CRMExportPreview.audioData(audioURL)
            operation.state = .sending; try journal.save(operation)
            do {
                operation.activityID = try await client.createMeeting(operation, context: bound, audio: audio)
                try journal.save(operation)
                try await client.verifyExport(operation, activityID: operation.activityID!)
                operation.state = .completed; operation.updated = Date(); try journal.save(operation)
                if isCurrent() { exportOperation = operation; preview = nil; error = nil }
            } catch {
                // Even a malformed response may follow a successful server write. Never retry blindly.
                if operation.activityID != nil { operation.state = .needsReconciliation }
                else if case BitrixFailure.rejected = error { operation.state = .rejected }
                else if case BitrixFailure.permission = error { operation.state = .rejected }
                else { operation.state = .needsReconciliation }
                operation.updated = Date(); try journal.save(operation)
                if isCurrent() { exportOperation = operation; preview = nil }
                throw error
            }
        } catch {
            if isCurrent() {
                preview = nil
                self.error = L10n.error(error)
            }
        }
    }
    func reconcile(meetingID: UUID) async {
        guard !busy, activeMeetingID == meetingID, let client else { return }
        let requestGeneration = generation
        func isCurrent() -> Bool { activeMeetingID == meetingID && generation == requestGeneration }
        busy = true; defer { busy = false }
        do {
            let journal = try requireJournal()
            guard var operation = try journal.operation(meetingID: meetingID) else { return }
            if let id = try await client.findExport(operation) {
                operation.activityID = id; operation.state = .needsReconciliation; try journal.save(operation)
                try await client.verifyExport(operation, activityID: id)
                operation.state = .completed; operation.updated = Date()
                try journal.save(operation)
                if isCurrent() { exportOperation = operation; error = nil }
            } else {
                if isCurrent() { error = L10n.string("Результат пока не найден. Автоматический повтор отключён: проверьте карточку, права и повторите сверку позже.") }
            }
        } catch { if isCurrent() { self.error = L10n.error(error) } }
    }
    private func requireJournal() throws -> CRMJournal {
        guard let journal else { throw CopilotError.message(L10n.string("Журнал CRM недоступен. Отправка заблокирована.")) }
        return journal
    }
}
