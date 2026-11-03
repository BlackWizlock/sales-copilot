import Foundation
import CopilotCore

protocol BitrixTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}
private final class NoBitrixRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct LiveBitrixTransport: BitrixTransport {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 90
        session = URLSession(configuration: config, delegate: NoBitrixRedirect(), delegateQueue: nil)
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
enum BitrixFailure: LocalizedError {
    case permission, rejected(String), network, malformed
    var errorDescription: String? {
        switch self {
        case .permission: return L10n.string("Битрикс24 отказал в доступе. Проверьте права личного вебхука и пользователя.")
        case .rejected(let code): return L10n.format("Битрикс24 отклонил запрос (%@).", String(describing: code))
        case .network: return L10n.string("Нет подтверждённого ответа Битрикс24. Для отправки требуется сверка перед повтором.")
        case .malformed: return L10n.string("Битрикс24 вернул неожиданный ответ.")
        }
    }
}
struct BitrixConnectionStatus: Sendable {
    var userID: String
    var scopes: [String]
    var message: String
}
struct BitrixDealChoice: Identifiable, Sendable { var id: String; var title: String }
struct CalendarDealDetails: Sendable {
    var title: String
    var client: String
    var url: URL
}

actor BitrixClient {
    private let credentials: BitrixCredentials
    private let transport: any BitrixTransport
    private var lastCall = Date.distantPast
    init(credentials: BitrixCredentials, transport: any BitrixTransport = LiveBitrixTransport()) { self.credentials = credentials; self.transport = transport }
    private func call(_ method: String, _ params: [String: CRMValue] = [:]) async throws -> [String: CRMValue] {
        let gap = 0.55 - Date().timeIntervalSince(lastCall)
        if gap > 0 { try await Task.sleep(for: .seconds(gap)) }
        lastCall = Date()
        var request = URLRequest(url: credentials.endpoint(method: method))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(params)
        let data: Data; let status: Int
        do { (data, status) = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw BitrixFailure.network } // Never surface URLSession's credential-bearing URL.
        guard !(300..<400).contains(status) else { throw BitrixFailure.rejected("REDIRECT") }
        guard let envelope = try? JSONDecoder().decode([String: CRMValue].self, from: data) else { throw BitrixFailure.malformed }
        if let error = envelope["error"]?.text, !error.isEmpty {
            if ["insufficient_scope", "ACCESS_DENIED", "INVALID_CREDENTIALS", "NO_AUTH_FOUND", "INVALID_TOKEN", "ERROR_ACCESS_DENIED"].contains(error) { throw BitrixFailure.permission }
            let safeCode = error.range(of: "^[A-Za-z0-9_.-]{1,80}$", options: .regularExpression) != nil ? error : "API_ERROR"
            throw BitrixFailure.rejected(safeCode)
        }
        guard (200..<300).contains(status), envelope["result"] != nil else { throw BitrixFailure.malformed }
        return envelope
    }
    private func list(_ method: String, _ params: [String: CRMValue]) async throws -> [[String: CRMValue]] {
        var params = params; var rows: [[String: CRMValue]] = []; var seen = Set<String>()
        for _ in 0..<200 {
            let result = try await call(method, params)
            guard case .array(let values) = result["result"] else { throw BitrixFailure.malformed }
            rows += values.map(\.object)
            guard let next = result["next"], !next.text.isEmpty else { return rows }
            guard seen.insert(next.text).inserted else { throw BitrixFailure.malformed }
            params["start"] = next
        }
        throw CopilotError.message(L10n.string("Слишком много записей CRM. Уточните выбор; неполный список не используется."))
    }
    func checkConnection() async throws -> BitrixConnectionStatus {
        let user = try await call("user.current")["result"]?.object ?? [:]
        let scopes = try await call("scope")["result"]?.array.map(\.text) ?? []
        guard let id = user["ID"]?.text, !id.isEmpty else { throw BitrixFailure.malformed }
        return BitrixConnectionStatus(userID: id, scopes: scopes, message: L10n.format("Подключён пользователь №%@. Права: %@. Чтение конкретной сделки и календаря проверяется при загрузке; запись ещё не проверена.", String(describing: id), String(describing: scopes.joined(separator: ", "))))
    }
    func searchDeals(_ query: String) async throws -> [BitrixDealChoice] {
        let filter: [String: CRMValue] = query.isEmpty ? ["CLOSED": .string("N")] : ["%TITLE": .string(query)]
        return try await list("crm.deal.list", ["filter": .object(filter), "select": .array([.string("ID"), .string("TITLE")]), "order": .object(["DATE_MODIFY": .string("DESC")])]).map { BitrixDealChoice(id: $0["ID"]?.text ?? "", title: $0["TITLE"]?.text ?? "") }
    }
    func calendarDeal(_ id: String) async throws -> CalendarDealDetails {
        guard Int(id).map({ $0 > 0 }) == true else { throw BitrixFailure.malformed }
        let fields = Self.sanitize(try await call("crm.deal.get", ["id": .string(id)])["result"] ?? .null).object
        guard fields["ID"]?.text == id, let title = fields["TITLE"]?.text, !title.isEmpty else { throw BitrixFailure.malformed }
        var name = ""
        if let company = fields["COMPANY_ID"]?.text, Int(company).map({ $0 > 0 }) == true {
            name = (try? await call("crm.company.get", ["id": .string(company)])["result"]?.object["TITLE"]?.text) ?? ""
        }
        if name.isEmpty, let contact = fields["CONTACT_ID"]?.text, Int(contact).map({ $0 > 0 }) == true {
            if let value = try? await call("crm.contact.get", ["id": .string(contact)])["result"]?.object {
                name = [value["NAME"]?.text, value["LAST_NAME"]?.text].compactMap { $0 }.joined(separator: " ")
            }
        }
        return CalendarDealDetails(title: title, client: name, url: URL(string: "https://\(credentials.portal)/crm/deal/details/\(id)/")!)
    }
    func updateCalendarDescription(_ event: CalendarMeeting, description: String, ownerID: String) async throws {
        guard description.count <= 10_000, Int(event.id).map({ $0 > 0 }) == true,
              Int(ownerID).map({ $0 > 0 }) == true else { throw BitrixFailure.malformed }
        let current = Self.sanitize(try await call("calendar.event.getbyid", ["id": .string(event.id)])["result"] ?? .null).object
        guard current["ID"]?.text == event.id,
              current["DESCRIPTION"]?.text ?? "" == event.raw["DESCRIPTION"]?.text ?? "",
              current["TIMESTAMP_X_ISO"] == event.raw["TIMESTAMP_X_ISO"],
              current["TIMESTAMP_X"] == event.raw["TIMESTAMP_X"] else {
            throw CopilotError.message(L10n.string("Событие изменилось в Битрикс24. Обновите календарь и откройте редактор заново; ваш текст остаётся в редакторе."))
        }
        var params: [String: CRMValue] = ["id": .string(event.id), "type": .string("user"), "ownerId": .string(ownerID), "description": .string(description)]
        if !current["RRULE", default: .null].object.isEmpty || Int(current["RECURRENCE_ID"]?.text ?? "0").map({ $0 > 0 }) == true {
            guard let zone = event.timezone.flatMap(TimeZone.init(identifier:)) else {
                throw CopilotError.message(L10n.string("Для изменения повторяющейся встречи нужен её часовой пояс. Серия не изменена."))
            }
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone; f.dateFormat = "yyyy-MM-dd"
            params["recurrence_mode"] = .string("this"); params["current_date_from"] = .string(f.string(from: event.starts))
        }
        let result = try await call("calendar.event.update", params)
        guard let value = result["result"], value != .null, value != .bool(false) else { throw BitrixFailure.malformed }
    }
    func calendar(ownerID: String, from: Date = Date().addingTimeInterval(-86400), to: Date = Date().addingTimeInterval(14 * 86400)) async throws -> [CalendarMeeting] {
        let iso = ISO8601DateFormatter()
        let result = try await call("calendar.event.get", ["type": .string("user"), "ownerId": .string(ownerID), "from": .string(iso.string(from: from)), "to": .string(iso.string(from: to))])
        guard case .array(let events) = result["result"] else { throw BitrixFailure.malformed }
        return try events.map { try CalendarMeeting.decode(Self.sanitize($0).object) }.sorted { $0.starts < $1.starts }
    }
    func loadDeal(id: String, calendarOwner: String) async throws -> DealContext {
        guard Int(id).map({ $0 > 0 }) == true else { throw CopilotError.message(L10n.string("Неверный номер сделки")) }
        let fields = Self.sanitize(try await call("crm.deal.get", ["id": .string(id)])["result"] ?? .null).object
        guard fields["ID"]?.text == id else { throw BitrixFailure.malformed }
        let config = Self.sanitize(try await call("crm.item.details.configuration.get", ["entityTypeId": .number(2)])["result"] ?? .null)
        let activities = try await list("crm.activity.list", ["filter": .object(["OWNER_TYPE_ID": .number(2), "OWNER_ID": .string(id)]), "select": .array(["*", "COMMUNICATIONS", "FILES", "STORAGE_ELEMENT_IDS"].map(CRMValue.string)), "order": .object(["LAST_UPDATED": .string("DESC")])]).map { Self.sanitize(.object($0)).object }
        var warnings: [String] = []
        var events: [CalendarMeeting] = []
        do { events = try await calendar(ownerID: calendarOwner, from: Date().addingTimeInterval(-30 * 86400), to: Date().addingTimeInterval(60 * 86400)).filter { $0.dealIDs.contains(id) } }
        catch { warnings.append(L10n.format("Календарь сделки не прочитан: %@", String(describing: L10n.error(error)))) }
        var client = ""
        if let company = fields["COMPANY_ID"]?.text, let n = Int(company), n > 0 {
            do { client = try await call("crm.company.get", ["id": .string(company)])["result"]?.object["TITLE"]?.text ?? "" }
            catch { warnings.append(L10n.string("Название компании недоступно")) }
        }
        if client.isEmpty, let contact = fields["CONTACT_ID"]?.text, let n = Int(contact), n > 0 {
            do { let c = try await call("crm.contact.get", ["id": .string(contact)])["result"]?.object ?? [:]; client = [c["NAME"]?.text, c["LAST_NAME"]?.text].compactMap { $0 }.joined(separator: " ") }
            catch { warnings.append(L10n.string("Имя контакта недоступно")) }
        }
        warnings.append(L10n.string("КП и документы показаны как ссылки или ID полей. Содержание и последняя архивная версия не подтверждены."))
        return DealContext(portal: credentials.portal, dealID: id, title: fields["TITLE"]?.text ?? "", client: client, fields: fields, fieldConfiguration: config, activities: activities, events: events, warnings: warnings)
    }
    func findExport(_ operation: CRMExport) async throws -> String? {
        guard operation.preview.portal == credentials.portal else { throw CopilotError.message(L10n.string("Подключён другой портал. Подключите исходный портал встречи.")) }
        let rows = try await list("crm.activity.list", ["filter": .object(["OWNER_TYPE_ID": .number(2), "OWNER_ID": .string(operation.preview.dealID), "ORIGINATOR_ID": .string("AXIS_COPILOT"), "ORIGIN_ID": .string(operation.marker)]), "select": .array(["ID", "ORIGIN_ID", "OWNER_ID"].map(CRMValue.string))])
        guard rows.count <= 1 else { throw CopilotError.message(L10n.string("Найдено несколько результатов. Проверьте карточку вручную.")) }
        return rows.first?["ID"]?.text
    }
    static func meetingCommunication(_ context: DealContext) throws -> (id: String, type: Double) {
        let contact = context.fields["CONTACT_ID"]?.text ?? ""
        let company = context.fields["COMPANY_ID"]?.text ?? ""
        let entityID: String; let entityType: Double
        if Int(contact).map({ $0 > 0 }) == true { entityID = contact; entityType = 3 }
        else if Int(company).map({ $0 > 0 }) == true { entityID = company; entityType = 4 }
        else { throw CopilotError.message(L10n.string("У сделки нет контакта или компании для обычного дела встречи. Добавьте клиента в карточку; поля приложение не меняет.")) }
        return (entityID, entityType)
    }
    func createMeeting(_ operation: CRMExport, context: DealContext, audio: Data?) async throws -> String {
        let p = operation.preview
        guard context.dealID == p.dealID, context.portal == p.portal, p.portal == credentials.portal else { throw CopilotError.message(L10n.string("Целевая сделка изменилась")) }
        let communication = try Self.meetingCommunication(context)
        let iso = ISO8601DateFormatter()
        var files: [CRMValue] = [.object(["fileData": .array([.string("transcript.txt"), .string(Data(p.transcript.utf8).base64EncodedString())])])]
        if let audio, let name = p.audioName { files.append(.object(["fileData": .array([.string(name), .string(audio.base64EncodedString())])])) }
        let result = try await call("crm.activity.add", ["fields": .object([
            "OWNER_TYPE_ID": .number(2), "OWNER_ID": .string(p.dealID), "TYPE_ID": .number(1), "SUBJECT": .string(p.title),
            "START_TIME": .string(iso.string(from: p.started)), "END_TIME": .string(iso.string(from: p.ended)), "COMPLETED": .string("Y"),
            "RESPONSIBLE_ID": context.fields["ASSIGNED_BY_ID"] ?? .string(credentials.userID),
            "COMMUNICATIONS": .array([.object(["ENTITY_ID": .string(communication.id), "ENTITY_TYPE_ID": .number(communication.type), "VALUE": .string("")])]),
            "DESCRIPTION": .string(operation.activityDescription), "DESCRIPTION_TYPE": .number(1),
            "ORIGINATOR_ID": .string("AXIS_COPILOT"), "ORIGIN_ID": .string(operation.marker), "FILES": .array(files)
        ])])
        guard let id = result["result"]?.text, Int(id).map({ $0 > 0 }) == true else { throw BitrixFailure.malformed }
        return id
    }
    func validateExportAccess() async throws {
        let scopes = try await call("scope")["result"]?.array.map(\.text) ?? []
        guard scopes.contains("crm"), scopes.contains("disk") else {
            throw CopilotError.message(L10n.string("Для сохранения и проверки вложений включите права CRM (crm) и Диск (disk) в настройках личного вебхука. Отправка не выполнена."))
        }
    }
    /// A successful write response alone does not prove the meeting's content was stored.
    func verifyExport(_ operation: CRMExport, activityID: String) async throws {
        guard operation.preview.portal == credentials.portal else { throw BitrixFailure.malformed }
        let fields = try await call("crm.activity.get", ["id": .string(activityID)])["result"]?.object ?? [:]
        let expectedDescription = operation.activityDescription
        guard fields["ID"]?.text == activityID,
              fields["OWNER_TYPE_ID"]?.text == "2", fields["OWNER_ID"]?.text == operation.preview.dealID,
              fields["ORIGINATOR_ID"]?.text == "AXIS_COPILOT", fields["ORIGIN_ID"]?.text == operation.marker,
              fields["DESCRIPTION"]?.text == expectedDescription,
              fields["COMPLETED"]?.text == "Y" else {
            throw CopilotError.message(L10n.string("Дело найдено, но итоги или вложения ещё не подтверждены. Повторная отправка отключена; сверьте результат позже."))
        }
        // FILES must be explicitly selected; get does not promise this field.
        let rows = try await list("crm.activity.list", ["filter": .object(["ID": .string(activityID)]), "select": .array([.string("ID"), .string("FILES")])])
        guard rows.count == 1, rows[0]["ID"]?.text == activityID else { throw BitrixFailure.malformed }
        let files = rows[0]["FILES"]?.array ?? []
        var expected = [(hash: CRMExportPreview.sha256(Data(operation.preview.transcript.utf8)), bytes: Data(operation.preview.transcript.utf8).count)]
        if operation.preview.audioName != nil {
            guard let audioHash = operation.preview.audioSHA256 else { throw BitrixFailure.malformed }
            expected.append((hash: audioHash, bytes: operation.preview.audioBytes))
        }
        guard files.count == expected.count else { throw BitrixFailure.malformed }
        for file in files {
            let values = file.object
            guard let fileID = values["id"]?.text, Int(fileID).map({ $0 > 0 }) == true,
                  let raw = values["url"]?.text, let url = URL(string: raw),
                  url.scheme == "https", url.host == credentials.portal, url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443,
                  url.path == "/bitrix/tools/crm_show_file.php",
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.queryItems?.first(where: { $0.name == "fileId" })?.value == fileID,
                  parts.queryItems?.first(where: { $0.name == "ownerId" })?.value == activityID,
                  parts.queryItems?.first(where: { $0.name == "ownerTypeId" })?.value == "6" else { throw BitrixFailure.malformed }
            // FILES.id identifies the attached Drive object. The browser URL above proves
            // its activity binding, but cannot authenticate a machine download with a webhook.
            let disk = try await call("disk.file.get", ["id": .string(fileID)])["result"]?.object ?? [:]
            guard disk["ID"]?.text == fileID, disk["TYPE"]?.text == "file",
                  let sizeText = disk["SIZE"]?.text, let size = Int(sizeText), size >= 0, size <= 50 * 1024 * 1024,
                  let machineRaw = disk["DOWNLOAD_URL"]?.text,
                  let machine = URLComponents(string: machineRaw),
                  machine.scheme == "https", machine.host == credentials.portal,
                  machine.user == nil, machine.password == nil, machine.fragment == nil,
                  machine.port == nil || machine.port == 443,
                  machine.path == "/rest/download.json" || machine.path.range(of: "^/rest/[0-9]+/[A-Za-z0-9_-]+/download/?$", options: .regularExpression) != nil,
                  let downloadURL = machine.url,
                  machine.queryItems?.contains(where: { $0.name == "token" && !($0.value ?? "").isEmpty }) == true else { throw BitrixFailure.malformed }
            // Drive may rename collisions (e.g. transcript (1).txt). Names are
            // display metadata; activity binding and exact bytes establish identity.
            guard expected.contains(where: { $0.bytes == size }) else { throw BitrixFailure.malformed }
            var request = URLRequest(url: downloadURL); request.httpMethod = "GET"
            request.setValue("AxisCopilot/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("https://\(credentials.portal)/", forHTTPHeaderField: "Referer")
            let data: Data; let status: Int
            do { (data, status) = try await transport.send(request) }
            catch is CancellationError { throw CancellationError() }
            catch { throw BitrixFailure.network }
            guard status == 200, data.count == size,
                  let index = expected.firstIndex(where: { $0.bytes == size && $0.hash == CRMExportPreview.sha256(data) }) else { throw BitrixFailure.malformed }
            expected.remove(at: index)
        }
        guard expected.isEmpty else { throw BitrixFailure.malformed }
    }
    /// Remove credential-bearing links before any CRM response becomes a persistent/prompt snapshot.
    static func sanitize(_ value: CRMValue) -> CRMValue {
        switch value {
        case .array(let a): return .array(a.map(sanitize))
        case .object(let o): return .object(o.filter { !["auth", "access_token", "refresh_token"].contains($0.key.lowercased()) }.mapValues(sanitize))
        case .string(let s):
            var result = s
            for pattern in ["https?://[^\\s\\\"'<>]+/rest/[0-9]+/[^\\s\\\"'<>]+", "(?i)([?&](?:auth|access_token|refresh_token|token)=)[^&\\s\\\"'<>]+"] {
                if let regex = try? NSRegularExpression(pattern: pattern) { result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[скрыто]") }
            }
            return .string(result)
        default: return value
        }
    }
}
