import Foundation
import CopilotCore

private final class LoopbackInferenceDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never allow a loopback endpoint to redirect meeting text to another host.
        completionHandler(nil)
    }
}

/// All inference URLs are fixed loopback addresses. There is no cloud fallback.
@MainActor final class IntelligenceRuntime: ObservableObject {
    static let shared = IntelligenceRuntime()
    static let model = "qwen2.5:7b"
    @Published var availableModels: [String] = []
    @Published var selectedModel = UserDefaults.standard.string(forKey: "localLanguageModel") ?? "qwen2.5:7b" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "localLanguageModel") }
    }
    var activeModel: String { availableModels.contains(selectedModel) ? selectedModel : Self.model }
    @Published var status = L10n.string("Локальная модель не проверена")
    @Published var preparing = false
    private var server: Process?
    private let endpoint = URL(string: "http://127.0.0.1:11434")!
    private let network: URLSession
    init(network: URLSession? = nil) { self.network = network ?? Self.makeNetwork() }
    private static func makeNetwork() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config, delegate: LoopbackInferenceDelegate(), delegateQueue: nil)
    }
    func prepare() async {
        guard !preparing else { return }
        preparing = true
        defer { preparing = false }
        do {
            try await ensureServer()
            struct Tags: Decodable { struct Model: Decodable { let name: String; let size: Int?; let remote_host: String? }; let models: [Model] }
            let tags = try JSONDecoder().decode(Tags.self, from: await request(path: "/api/tags", body: nil))
            if !tags.models.contains(where: { $0.name == Self.model }) {
                status = L10n.string("Подготовка Qwen2.5 7B (первая загрузка около 4,7 ГБ)…")
                _ = try await request(path: "/api/pull", body: ["model": Self.model, "stream": false])
            }
            let installed = try JSONDecoder().decode(Tags.self, from: await request(path: "/api/tags", body: nil))
            availableModels = installed.models.filter { ($0.size ?? 0) > 100_000_000 && $0.remote_host == nil && !$0.name.contains("-cloud") }.map(\.name).sorted()
            if !availableModels.contains(selectedModel) { selectedModel = Self.model }
            status = L10n.string("Локальная модель готова. Обработка только на Mac")
        } catch { status = L10n.error(error) }
    }
    private func ensureServer() async throws {
            if (try? await request(path: "/api/tags", body: nil)) == nil {
                let candidates = [Bundle.main.resourceURL?.appendingPathComponent("Tools/Ollama/ollama").path, Bundle.main.resourceURL?.appendingPathComponent("Tools/ollama").path, "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"].compactMap { $0 }
                guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                    throw CopilotError.message(L10n.string("Нужен локальный движок Ollama. Установите Ollama для macOS или используйте комплект с Tools/ollama."))
                }
                let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["serve"]
                var env = ProcessInfo.processInfo.environment
                env["OLLAMA_HOST"] = "127.0.0.1:11434"; env["OLLAMA_NO_CLOUD"] = "1"; env["OLLAMA_DEBUG_LOG_REQUESTS"] = "false"
                process.environment = env; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                if server?.isRunning != true { try process.run(); server = process }
                for _ in 0..<30 {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    if (try? await request(path: "/api/tags", body: nil)) != nil { break }
                }
            }
    }
    func request(path: String, body: [String: Any]?) async throws -> Data {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        if let body { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await network.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw CopilotError.message(L10n.string("Локальная модель недоступна. Нажмите «Подготовить локальный ИИ»."))
        }
        return data
    }
    func generate(system: String, prompt: String, schema: [String: Any]? = nil, maximumTokens: Int = 1800) async throws -> String {
        guard prompt.count < 100_000 else { throw CopilotError.message(L10n.string("Материал слишком большой для локального контекста. Разделите встречу или сократите материалы.")) }
        try await ensureServer()
        let data = try await request(path: "/api/generate", body: ["model": activeModel, "system": system, "prompt": prompt, "stream": false, "format": schema as Any? ?? "json", "options": ["temperature": 0, "num_ctx": 32768, "num_predict": min(4096, max(256, maximumTokens))]])
        struct Response: Decodable { var response: String; var done: Bool; var done_reason: String? }
        let result = try JSONDecoder().decode(Response.self, from: data)
        guard result.done, result.done_reason != "length" else {
            throw CopilotError.message(L10n.string("Модель не закончила ответ в пределах лимита. Повторите запрос или выберите другую локальную модель."))
        }
        try Task.checkCancellation()
        return result.response
    }
}
