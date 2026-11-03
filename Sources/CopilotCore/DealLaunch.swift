import Foundation

/// Untrusted navigation data only. This type never contains credentials or actions.
public struct DealLaunchRequest: Equatable, Sendable {
    public let portal: String
    public let dealID: String

    public init(_ text: String) throws {
        // A deliberately narrow wire format avoids URL normalization, double decoding,
        // alternate authorities and credential-bearing URLs before Foundation parses it.
        guard text.utf8.count <= 512,
              text.range(of: "^axis-copilot://deal\\?(?:portal=[a-z0-9.-]+&id=[0-9]+|id=[0-9]+&portal=[a-z0-9.-]+)$", options: .regularExpression) != nil,
              !text.contains(where: { $0.isWhitespace }),
              let parts = URLComponents(string: text), parts.scheme == "axis-copilot", parts.host == "deal",
              parts.path.isEmpty, parts.fragment == nil, parts.user == nil, parts.password == nil, parts.port == nil,
              let items = parts.queryItems, items.count == 2,
              let portal = items.first(where: { $0.name == "portal" })?.value, BitrixPortal.isAllowed(portal),
              let rawID = items.first(where: { $0.name == "id" })?.value,
              let id = Int(rawID), id > 0 else {
            throw CopilotError.message("Недопустимая ссылка сделки. Нужны только разрешённый портал и положительный номер сделки.")
        }
        self.portal = portal; self.dealID = String(id)
    }

    public var dealURL: URL { URL(string: "https://\(portal)/crm/deal/details/\(dealID)/")! }
}

public struct DealLaunchPreview: Equatable, Sendable {
    public let title: String
    public let client: String
    public init(title: String, client: String) { self.title = title; self.client = client }
}

public struct DealLaunchState: Equatable, Sendable {
    public var portal: String?
    public var busy: Bool
    /// Changes even if a connection or operation briefly changes and returns to its old value.
    public var revision: UInt64
    public init(portal: String?, busy: Bool, revision: UInt64) {
        self.portal = portal; self.busy = busy; self.revision = revision
    }
}

/// Shared orchestration lets synthetic tests exercise cancellation without showing AppKit UI.
@MainActor public final class DealLaunchPreparation {
    public enum Result { case prepared, cancelled, stale }
    public private(set) var running = false
    public init() {}

    public func prepare(_ request: DealLaunchRequest,
                        state: () -> DealLaunchState,
                        read: (DealLaunchRequest) async throws -> DealLaunchPreview,
                        confirm: (DealLaunchPreview) async -> Bool,
                        apply: () async -> Void) async throws -> Result {
        guard !running else { throw CopilotError.message("Подготовка другой сделки уже выполняется. Дождитесь её завершения.") }
        let original = state()
        guard !original.busy else { throw CopilotError.message("Завершите запись или текущую операцию перед открытием сделки.") }
        guard original.portal == request.portal else {
            throw CopilotError.message("Сначала подключите в настройках портал \(request.portal). Ссылка не меняет подключение.")
        }
        running = true; defer { running = false }
        let preview = try await read(request)
        guard !Task.isCancelled, state() == original else { return .stale }
        guard await confirm(preview) else { return .cancelled }
        guard !Task.isCancelled, state() == original else { return .stale }
        await apply()
        return .prepared
    }
}
