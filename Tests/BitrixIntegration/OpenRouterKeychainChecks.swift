import Foundation
import Security
@main struct KeychainChecks {
    @MainActor static func main() async throws {
        let service = "ru.axisconsult.copilot.synthetic-keychain-check." + UUID().uuidString
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let blocker = Task.detached {
            KeychainAccess.serialized {
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        _ = try await KeychainAccess.offMain { entered.wait() }
        let started = Date()
        let sandbox = OpenRouterSandbox(keyService: service)
        precondition(Date().timeIntervalSince(started) < 0.5, "Opening settings must not wait for another Keychain request")
        let loading = Task { @MainActor in await sandbox.loadSavedKey() }
        await Task.yield()
        precondition(sandbox.keyBusy, "The pending read must yield the UI actor")
        release.signal(); await blocker.value; await loading.value
        precondition(!sandbox.keyBusy && !sandbox.hasKey)
        defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "personal"] as CFDictionary) }
        func read() -> String? {
            var result: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "personal", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        precondition(read() == nil)
        sandbox.keyInput = "SYNTHETIC-NOT-A-VALID-KEY-A"; await sandbox.saveKey()
        precondition(sandbox.hasKey && sandbox.keyInput.isEmpty && read() == "SYNTHETIC-NOT-A-VALID-KEY-A")
        sandbox.keyInput = "SYNTHETIC-NOT-A-VALID-KEY-B"; await sandbox.saveKey()
        precondition(sandbox.hasKey && sandbox.keyInput.isEmpty && read() == "SYNTHETIC-NOT-A-VALID-KEY-B")
        await sandbox.removeKey()
        precondition(!sandbox.hasKey && read() == nil)
        print("PASS: dedicated synthetic Keychain service save/load/replace/remove; no real service accessed")
    }
}
