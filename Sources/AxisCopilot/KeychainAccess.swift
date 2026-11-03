import Foundation
import Security

/// Legacy login-keychain ACL dialogs are not suppressed by kSecUseAuthenticationUIFail alone.
/// The process-wide interaction switch is held only across this synchronous call and restored.
enum KeychainAccess {
    private static let lock = NSRecursiveLock()
    static func serialized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try operation()
    }
    /// Security can wait for a system prompt indefinitely. Never hold the UI actor.
    static func offMain<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: operation).value
    }
    static func copy(_ query: [String: Any], allowInteraction: Bool, result: inout CFTypeRef?) -> OSStatus {
        serialized {
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
}
