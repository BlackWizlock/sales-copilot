import Foundation
import Combine
import Security
import CopilotCore

private final class OpenRouterRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Separate synthetic sandbox: this type intentionally has no meeting, CRM or proposal API.
@MainActor final class OpenRouterSandbox: ObservableObject {
    static let shared = OpenRouterSandbox()
    struct Model: Decodable, Identifiable {
        let id: String
        let name: String
        let pricing: [String: String]
        let unsupportedPricing: Bool
        private enum CodingKeys: String, CodingKey { case id, name, pricing, supported_parameters }
        private struct PriceKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = (try? container.decode(String.self, forKey: .name)) ?? id
            supported_parameters = try? container.decode([String].self, forKey: .supported_parameters)
            var prices: [String: String] = [:]; var unsupported = false
            if let values = try? container.nestedContainer(keyedBy: PriceKey.self, forKey: .pricing) {
                for key in values.allKeys {
                    if let value = try? values.decode(String.self, forKey: key) { prices[key.stringValue] = value }
                    else { unsupported = true }
                }
            } else { unsupported = true }
            pricing = prices; unsupportedPricing = unsupported
        }
        let supported_parameters: [String]?
        var safePrices: (Decimal, Decimal, Decimal)? {
            guard !unsupportedPricing else { return nil }
            guard let input = pricing["prompt"].flatMap({ Decimal(string: $0) }), let output = pricing["completion"].flatMap({ Decimal(string: $0) }), input >= 0, output >= 0, !input.isNaN, !output.isNaN else { return nil }
            let request = pricing["request"].flatMap({ Decimal(string: $0) }) ?? 0
            guard request >= 0, !request.isNaN else { return nil }
            // Reject unknown nonzero price components, such as web search or images.
            for (name, value) in pricing where !["prompt", "completion", "request"].contains(name) {
                guard let amount = Decimal(string: value), !amount.isNaN, amount == 0 else { return nil }
            }
            return (input, output, request)
        }
    }
    @Published var enabled = false
    @Published var keyInput = ""
    @Published var hasKey = false
    @Published private(set) var keyBusy = false
    @Published var status = ""
    @Published var models: [Model] = []
    @Published var selectedModel = ""
    @Published var budgetText = "0" { didSet { UserDefaults.standard.set(budgetText, forKey: "openRouterDailyBudget") } }
    @Published var prompt = ""
    @Published var attested = false
    @Published var reply = ""
    @Published var actualModel = ""
    @Published var busy = false
    @Published var chargedText = "0"
    private var ledger: CloudBudgetLedger
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var catalogDate: Date?
    private let keyService: String
    private let network: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90; config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: OpenRouterRedirectDelegate(), delegateQueue: nil)
    }()
    init(keyService: String = "ru.axisconsult.copilot.openrouter") {
        self.keyService = keyService
        budgetText = UserDefaults.standard.string(forKey: "openRouterDailyBudget") ?? "0"
        if let data = UserDefaults.standard.data(forKey: "openRouterBudgetLedger") {
            ledger = (try? JSONDecoder().decode(CloudBudgetLedger.self, from: data)) ?? CloudBudgetLedger(day: Self.day, charged: 1_000_000_000)
        } else { ledger = CloudBudgetLedger(day: Self.day) }
        refreshLedger()
    }
    private static var day: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }
    private func refreshLedger() {
        chargedText = NSDecimalNumber(decimal: ledger.day == Self.day ? ledger.charged : 0).stringValue
        if let data = try? JSONEncoder().encode(ledger) { UserDefaults.standard.set(data, forKey: "openRouterBudgetLedger") }
    }
    private var keyQuery: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keyService, kSecAttrAccount as String: "personal"] }
    private func readKey(allowInteraction: Bool = false) async throws -> String? {
        let service = keyService
        return try await KeychainAccess.offMain {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "personal"]
        query[kSecUseAuthenticationUI as String] = allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = KeychainAccess.copy(query, allowInteraction: allowInteraction, result: &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw CopilotError.message(L10n.string("Связка ключей не разрешила доступ")) }
        return key
        }
    }
    func loadSavedKey() async {
        guard !keyBusy else { return }; keyBusy = true; defer { keyBusy = false }
        do { hasKey = try await readKey() != nil }
        catch { status = L10n.string("Ключ сохранён, но этой сборке нужен доступ. Нажмите «Разрешить доступ к ключу» в настройках OpenRouter.") }
    }
    func unlockKey() async {
        guard !keyBusy else { return }; keyBusy = true; defer { keyBusy = false }
        do { hasKey = try await readKey(allowInteraction: true) != nil; status = hasKey ? L10n.string("Доступ к ключу разрешён") : L10n.string("Сначала сохраните личный ключ") }
        catch { status = L10n.string("Связка ключей не разрешила доступ. Ключ не изменён.") }
    }
    func saveKey() {
        guard !keyBusy else { return }
        do {
            let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !key.contains("\n") else { throw CopilotError.message(L10n.string("Введите ключ API OpenRouter")) }
            let data = Data(key.utf8)
            let update = SecItemUpdate(keyQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if update == errSecItemNotFound {
                var add = keyQuery; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw CopilotError.message(L10n.string("Не удалось сохранить ключ в Связке ключей")) }
            } else if update != errSecSuccess { throw CopilotError.message(L10n.string("Не удалось обновить ключ в Связке ключей")) }
            keyInput = ""; hasKey = true; status = L10n.string("Ключ сохранён в Связке ключей этого Mac")
        } catch { status = L10n.error(error) }
    }
    func removeKey() {
        guard !keyBusy else { return }
        cancel(); let code = SecItemDelete(keyQuery as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { status = L10n.string("Не удалось удалить ключ из Связки ключей"); return }
        keyInput = ""; hasKey = false; enabled = false; status = L10n.string("Ключ удалён")
    }
    private func request(_ path: String, authenticated: Bool = true) async throws -> URLRequest {
        var r = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/" + path)!)
        if authenticated { guard let key = try await readKey() else { throw CopilotError.message(L10n.string("Сначала сохраните личный ключ")) }; r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        return r
    }
    func checkKey() async {
        guard !keyBusy else { return }; keyBusy = true; defer { keyBusy = false }
        do {
            let request = try await request("key")
            let (_, response) = try await network.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CopilotError.message(L10n.string("OpenRouter отклонил ключ или доступ к аккаунту")) }
            status = L10n.string("Ключ проверен. Запрос к модели не отправлялся.")
        } catch { status = L10n.error(error) }
    }
    func loadModels() async {
        do {
            let request = try await request("models", authenticated: false)
            let (data, response) = try await network.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CopilotError.message(L10n.string("Каталог моделей недоступен")) }
            models = try Self.decodeCatalog(data)
            catalogDate = Date(); if !models.contains(where: { $0.id == selectedModel }) { selectedModel = models.first?.id ?? "" }
            status = L10n.format("Каталог загружен: %@ моделей с поддерживаемыми ограниченными ценами. Неподдерживаемые цены исключены. Доступность зависит от аккаунта и поставщика.", String(models.count))
        } catch { status = L10n.error(error) }
    }
    /// Lossy only at the model boundary. Unknown pricing structures reject that model,
    /// never discard overrides and pretend a lower price is authoritative.
    static func decodeCatalog(_ data: Data) throws -> [Model] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = object["data"] as? [Any] else { throw CopilotError.message(L10n.string("Некорректный каталог моделей")) }
        return rows.compactMap { row -> Model? in
            guard JSONSerialization.isValidJSONObject(row), let encoded = try? JSONSerialization.data(withJSONObject: row), let model = try? JSONDecoder().decode(Model.self, from: encoded), model.safePrices != nil, model.supported_parameters?.contains("max_tokens") == true else { return nil }
            return model
        }.sorted { $0.name < $1.name }
    }
    var selectedModelPriceDescription: String {
        guard let model = models.first(where: { $0.id == selectedModel }), let prices = model.safePrices else { return L10n.string("Цены недоступны. Обновите каталог.") }
        return L10n.format("USD / 1 млн токенов: вход $%@; выход $%@; за запрос $%@", NSDecimalNumber(decimal: prices.0 * 1_000_000).stringValue, NSDecimalNumber(decimal: prices.1 * 1_000_000).stringValue, NSDecimalNumber(decimal: prices.2).stringValue)
    }
    var estimate: Decimal? {
        guard let model = models.first(where: { $0.id == selectedModel }), let (input, output, request) = model.safePrices else { return nil }
        // UTF-8 bytes bound text tokens conservatively, plus chat framing and a small reserve.
        return (Decimal(prompt.utf8.count + 512) * input + 512 * output + request) * Decimal(string: "1.1")! + Decimal(string: "0.0001")!
    }
    var estimateText: String { estimate.map { NSDecimalNumber(decimal: $0).stringValue } ?? L10n.string("неизвестно") }
    func cancel() { task?.cancel(); generation = UUID(); busy = false }
    func contextChanged() { attested = false; cancel() }
    func send() {
        guard !busy else { return }
        guard enabled, hasKey, attested, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 12_000 else { status = L10n.string("Включите песочницу и подтвердите синтетический или публичный запрос объёмом до 12 КБ"); return }
        guard let date = catalogDate, Date().timeIntervalSince(date) < 3600, let model = models.first(where: { $0.id == selectedModel }), let prices = model.safePrices, let reserve = estimate, let limit = Decimal(string: budgetText.replacingOccurrences(of: ",", with: ".")) else { status = L10n.string("Сначала обновите цены моделей и укажите дневной бюджет"); return }
        do { try ledger.reserve(reserve, limit: limit, day: Self.day); refreshLedger() } catch { status = L10n.error(error); return }
        let token = UUID(); generation = token; busy = true; reply = ""; actualModel = ""
        let question = prompt
        task = Task {
            defer { if generation == token { busy = false } }
            do {
                var r = try await request("chat/completions"); try Task.checkCancellation()
                guard generation == token else { return }
                r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try JSONSerialization.data(withJSONObject: ["model": model.id, "messages": [["role": "user", "content": question]], "max_tokens": 512, "stream": true, "stream_options": ["include_usage": true], "provider": ["allow_fallbacks": false, "require_parameters": true, "data_collection": "deny", "max_price": ["prompt": NSDecimalNumber(decimal: prices.0 * 1_000_000), "completion": NSDecimalNumber(decimal: prices.1 * 1_000_000), "request": NSDecimalNumber(decimal: prices.2)]]])
                let (bytes, response) = try await network.bytes(for: r)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw CopilotError.message((response as? HTTPURLResponse)?.statusCode == 429 ? L10n.string("Лимит запросов OpenRouter. Повторите позже; бюджет остаётся зарезервированным.") : L10n.string("Запрос OpenRouter не выполнен; бюджет остаётся зарезервированным.")) }
                var reconciled = false
                for try await line in bytes.lines {
                    try Task.checkCancellation(); guard generation == token else { return }
                    guard line.hasPrefix("data: "), line != "data: [DONE]", let data = String(line.dropFirst(6)).data(using: .utf8), let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if let name = event["model"] as? String { actualModel = name }
                    if let choices = event["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any], let text = delta["content"] as? String { reply += text }
                    if !reconciled, let usage = event["usage"] as? [String: Any], let cost = usage["cost"] as? NSNumber {
                        reconciled = true
                        ledger.reconcile(reserved: reserve, actual: Decimal(string: cost.stringValue)); refreshLedger()
                    }
                }
                status = L10n.string("Запрос выполнен. Списания остаются оценкой до подтверждения расчётами поставщика.")
            } catch is CancellationError { } catch { if generation == token { status = L10n.error(error) } }
        }
    }
}
