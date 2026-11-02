import Foundation
import Security
import CopilotCore

/// The user explicitly pastes their own personal inbound webhook. No existing integration secrets are imported.
struct BitrixCredentials: Codable {
    let userID: String
    let secret: String
    let portal: String
    private static let account = "active-personal-portal"
    static let service = "ru.axisconsult.copilot.bitrix"
    init(webhook: String) throws {
        guard let u = URLComponents(string: webhook.trimmingCharacters(in: .whitespacesAndNewlines)),
              u.scheme == "https", u.host.map({ BitrixPortal.isAllowed($0.lowercased()) }) == true, u.user == nil, u.password == nil,
              u.port == nil || u.port == 443, u.query == nil, u.fragment == nil else { throw CopilotError.message(L10n.string("Нужен личный входящий вебхук https://YOUR-PORTAL.bitrix24.ru/rest/USER/SECRET/")) }
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "rest", Int(parts[1]).map({ $0 > 0 }) == true,
              parts[2].range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw CopilotError.message(L10n.string("Некорректный формат личного вебхука")) }
        portal = u.host!.lowercased(); userID = parts[1]; secret = parts[2]
    }
    func endpoint(method: String) -> URL { URL(string: "https://\(portal)/rest/\(userID)/\(secret)/\(method).json")! }
    func save(service: String = Self.service, account: String = Self.account) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let data = try JSONEncoder().encode(self)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw CopilotError.message(L10n.string("Не удалось сохранить подключение в Связке ключей")) }
        } else if status != errSecSuccess { throw CopilotError.message(L10n.string("Связка ключей не разрешила изменение подключения")) }
    }
    static func load(service: String = Self.service, account: String = Self.account, allowInteraction: Bool = false) throws -> BitrixCredentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationUI as String: allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        let status = KeychainAccess.copy(query, allowInteraction: allowInteraction, result: &result)
        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed { throw CopilotError.message(L10n.string("Для этой сборки требуется доступ к сохранённому подключению. Откройте настройки Битрикс24 и нажмите «Разрешить доступ к подключению». Ключ сохранён.")) }
        guard status == errSecSuccess, let data = result as? Data else { throw CopilotError.message(L10n.string("Связка ключей не разрешила чтение подключения")) }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    static func remove(service: String = Self.service, account: String = Self.account) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CopilotError.message(L10n.string("Связка ключей не разрешила отключение")) }
    }
}
