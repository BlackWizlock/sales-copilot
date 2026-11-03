import Foundation
import CopilotCore

/// Shared route for summaries, chat and automatic hints. Never starts a local LLM.
@MainActor final class IntelligenceRuntime: ObservableObject {
    typealias Generation = @MainActor (String, String, [String: Any]?, Int) async throws -> String
    static let shared = IntelligenceRuntime()
    private let generation: Generation?
    private let injectedModel: String?
    private let connection: OpenRouterSandbox
    var activeModel: String { injectedModel ?? connection.selectedModel }
    @Published var status = ""
    @Published var preparing = false
    init(generator: Generation? = nil, model: String? = nil, connection: OpenRouterSandbox? = nil) {
        generation = generator; injectedModel = model
        self.connection = connection ?? .shared
    }
    func prepare() async {
        guard !preparing else { return }
        preparing = true; defer { preparing = false }
        await connection.loadModels()
        status = connection.status
    }
    func generate(system: String, prompt: String, schema: [String: Any]? = nil, maximumTokens: Int = 1800) async throws -> String {
        try Task.checkCancellation()
        guard prompt.count < 100_000 else {
            throw CopilotError.message(L10n.string("Материал слишком большой. Разделите встречу или сократите материалы."))
        }
        let result: String
        if let generation { result = try await generation(system, prompt, schema, maximumTokens) }
        else { result = try await connection.generateMeeting(system: system, prompt: prompt, schema: schema, maximumTokens: maximumTokens) }
        try Task.checkCancellation()
        return result
    }
}
