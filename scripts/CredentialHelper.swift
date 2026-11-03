import Foundation
import Security
import CryptoKit

// This executable is installed once and reused byte-for-byte across app updates.
// No network, command arguments, environment credentials or arbitrary key names.
@main struct AxisCredentials {
    private struct Stored: Codable { let deleted: Bool; let data: Data? }
    static func main() {
        alarm(20)
        // Every storage operation is noninteractive, including update/delete.
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { exit(1) }
        do {
            let parent = getppid(), certificate = try CredentialIdentity.ownCertificate()
            try CredentialIdentity.validateProcess(parent, identifier: CredentialIdentity.application, certificate: certificate)
            guard getppid() == parent else { throw CredentialFailure.identity }
            try CredentialFraming.write(CredentialResponse(version: 1, status: 0, present: false, deleted: false, data: nil), to: .standardOutput)
            let input = try JSONDecoder().decode(CredentialRequest.self, from: CredentialFraming.read(.standardInput))
            guard input.version == 1, (input.data?.count ?? 0) <= 8_192 else { throw CredentialFailure.size }
            // Revalidate the same live parent immediately before Keychain access.
            guard getppid() == parent else { throw CredentialFailure.identity }
            try CredentialIdentity.validateProcess(parent, identifier: CredentialIdentity.application, certificate: certificate)
            let response = try perform(input)
            try CredentialFraming.write(response, to: .standardOutput)
        } catch {
            let status: Int32
            if case CredentialFailure.storage(let value) = error { status = value } else { status = errSecAuthFailed }
            try? CredentialFraming.write(CredentialResponse(version: 1, status: status, present: false, deleted: false, data: nil), to: .standardOutput)
            exit(1)
        }
    }
    private static func perform(_ request: CredentialRequest) throws -> CredentialResponse {
        #if CREDENTIAL_FIXTURE
        // Test builds use a separate namespace derived from their temporary location.
        // The distributed helper contains neither this branch nor a namespace override.
        let directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
        let suffix = SHA256.hash(data: Data(directory.utf8)).map { String(format: "%02x", $0) }.joined()
        let service = "ru.axisconsult.copilot.credential-fixture." + suffix + "." + request.domain.rawValue
        #else
        let service = "ru.axisconsult.copilot.credentials.v1." + request.domain.rawValue
        #endif
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "personal"]
        #if CREDENTIAL_FIXTURE
        if request.operation == .corrupt {
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data("invalid-json".utf8)] as CFDictionary)
            guard status == errSecSuccess else { throw CredentialFailure.storage(status) }
            return .init(version: 1, status: 0, present: true, deleted: false, data: nil)
        }
        if request.operation == .purge {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialFailure.storage(status) }
            return .init(version: 1, status: 0, present: false, deleted: false, data: nil)
        }
        #endif
        if request.operation == .read {
            guard request.data == nil else { throw CredentialFailure.protocolMismatch }
            var read = query
            read[kSecReturnData as String] = true
            read[kSecMatchLimit as String] = kSecMatchLimitOne
            read[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            var result: CFTypeRef?
            let status = SecItemCopyMatching(read as CFDictionary, &result)
            if status == errSecItemNotFound { return .init(version: 1, status: 0, present: false, deleted: false, data: nil) }
            guard status == errSecSuccess else { throw CredentialFailure.storage(status) }
            guard let data = result as? Data, data.count <= CredentialFraming.maximum else { throw CredentialFailure.size }
            let saved = try JSONDecoder().decode(Stored.self, from: data)
            guard saved.deleted ? saved.data == nil : saved.data != nil,
                  (saved.data?.count ?? 0) <= 8_192 else { throw CredentialFailure.protocolMismatch }
            return .init(version: 1, status: 0, present: true, deleted: saved.deleted, data: saved.deleted ? nil : saved.data)
        }
        guard request.operation == .delete || request.data != nil else { throw CredentialFailure.protocolMismatch }
        // A protected tombstone prevents an old legacy item being resurrected on restart.
        let data = try JSONEncoder().encode(Stored(deleted: request.operation == .delete, data: request.operation == .delete ? nil : request.data))
        if request.operation == .migrate {
            var add = query; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            // Atomic create-only migration: concurrent writes/tombstones always win.
            guard status == errSecSuccess || status == errSecDuplicateItem else { throw CredentialFailure.storage(status) }
            return .init(version: 1, status: 0, present: true, deleted: false, data: nil)
        }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialFailure.storage(status) }
        return .init(version: 1, status: 0, present: true, deleted: request.operation == .delete, data: nil)
    }
}
