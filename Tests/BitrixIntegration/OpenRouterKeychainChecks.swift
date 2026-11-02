import Foundation
import Security
@main struct KeychainChecks {
    @MainActor static func main() {
        let service = "ru.axisconsult.copilot.synthetic-keychain-check." + UUID().uuidString
        let sandbox = OpenRouterSandbox(keyService: service)
        defer { sandbox.removeKey() }
        func read() -> String? {
            var result: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "personal", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        precondition(read() == nil)
        sandbox.keyInput = "SYNTHETIC-NOT-A-VALID-KEY-A"; sandbox.saveKey()
        precondition(sandbox.hasKey && sandbox.keyInput.isEmpty && read() == "SYNTHETIC-NOT-A-VALID-KEY-A")
        sandbox.keyInput = "SYNTHETIC-NOT-A-VALID-KEY-B"; sandbox.saveKey()
        precondition(sandbox.hasKey && sandbox.keyInput.isEmpty && read() == "SYNTHETIC-NOT-A-VALID-KEY-B")
        sandbox.removeKey()
        precondition(!sandbox.hasKey && read() == nil)
        print("PASS: dedicated synthetic Keychain service save/load/replace/remove; no real service accessed")
    }
}
