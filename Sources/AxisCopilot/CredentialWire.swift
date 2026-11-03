import Foundation
import Security
import CryptoKit

enum CredentialDomain: String, Codable { case bitrix, openrouter }
enum CredentialOperation: String, Codable { case read, write, delete, migrate
    #if CREDENTIAL_FIXTURE
    case purge, corrupt
    #endif
}
struct CredentialRequest: Codable {
    let version: Int
    let domain: CredentialDomain
    let operation: CredentialOperation
    let data: Data?
}
struct CredentialResponse: Codable {
    let version: Int
    let status: Int32
    let present: Bool
    let deleted: Bool
    let data: Data?
}
enum CredentialFailure: Error { case identity, storage(Int32), protocolMismatch, size, path, timeout }

enum CredentialIdentity {
    static let application = "ru.axisconsult.SalesCopilot"
    static let helper = application + ".AxisCredentials"
    static func certificate(_ code: SecStaticCode) throws -> String {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let certs = values[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first else {
            throw CredentialFailure.identity
        }
        return Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
    }
    private static func staticCode(_ code: SecCode) throws -> SecStaticCode {
        var result: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &result) == errSecSuccess, let result else { throw CredentialFailure.identity }
        return result
    }
    static func ownCertificate() throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw CredentialFailure.identity }
        return try certificate(staticCode(code))
    }
    static func requirement(_ identifier: String, certificate: String) throws -> SecRequirement {
        guard certificate.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil else { throw CredentialFailure.identity }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(("identifier \"" + identifier + "\" and certificate leaf = H\"" + certificate + "\"") as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw CredentialFailure.identity }
        return requirement
    }
    private static func hardened(_ code: SecStaticCode) throws {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let flags = values[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & 0x10000 != 0 else { throw CredentialFailure.identity }
        let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        for key in ["com.apple.security.get-task-allow", "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-dyld-environment-variables"] {
            if entitlements[key] as? Bool == true { throw CredentialFailure.identity }
        }
    }
    static func codeHash(_ code: SecStaticCode) throws -> Data {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { throw CredentialFailure.identity }
        return hash
    }
    static func validateFile(_ url: URL, certificate: String) throws -> Data {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), try requirement(helper, certificate: certificate)) == errSecSuccess else {
            throw CredentialFailure.identity
        }
        try hardened(code)
        return try codeHash(code)
    }
    static func validateProcess(_ pid: pid_t, identifier: String, certificate: String, expectedHash: Data? = nil) throws {
        guard pid > 1 else { throw CredentialFailure.identity }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), try requirement(identifier, certificate: certificate)) == errSecSuccess else {
            throw CredentialFailure.identity
        }
        try hardened(staticCode(code))
        if let expectedHash {
            // Security's C API explicitly accepts SecCode and SecStaticCode objects.
            // Swift imports only the latter; preserve the live object for its cdhash.
            let live = unsafeBitCast(code, to: SecStaticCode.self)
            guard try codeHash(live) == expectedHash else { throw CredentialFailure.identity }
        }
    }
}

enum CredentialFraming {
    static let maximum = 16_384
    static func read(_ handle: FileHandle) throws -> Data {
        var result = Data()
        // One newline-delimited message. Read a byte at a time to avoid consuming
        // a second message or blocking for EOF while the peer awaits our reply.
        while let next = try handle.read(upToCount: 1), !next.isEmpty {
            if next[0] == 10 { return result }
            guard result.count < maximum else { throw CredentialFailure.size }
            result.append(next)
        }
        throw CredentialFailure.protocolMismatch
    }
    static func write<T: Encodable>(_ value: T, to handle: FileHandle) throws {
        var data = try JSONEncoder().encode(value)
        guard data.count <= maximum else { throw CredentialFailure.size }
        data.append(10)
        try handle.write(contentsOf: data)
    }
}
