import Foundation
import Security

/// Legacy login-keychain ACL dialogs are not suppressed by kSecUseAuthenticationUIFail alone.
/// The process-wide interaction switch is held only across this synchronous call and restored.
enum KeychainAccess {
    private static let lock = NSRecursiveLock()
    static func copy(_ query: [String: Any], allowInteraction: Bool, result: inout CFTypeRef?) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        var previous = DarwinBoolean(true)
        let original = SecKeychainGetUserInteractionAllowed(&previous)
        guard original == errSecSuccess else { return original }
        if !allowInteraction {
            let status = SecKeychainSetUserInteractionAllowed(false)
            guard status == errSecSuccess else { return status }
        }
        defer { if !allowInteraction { SecKeychainSetUserInteractionAllowed(previous.boolValue) } }
        return SecItemCopyMatching(query as CFDictionary, &result)
    }
}
