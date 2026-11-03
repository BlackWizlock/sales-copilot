import Foundation
import Security
import CryptoKit

/// Authenticated pipes to an immutable, hardened helper. No credential files.
struct CredentialBridge {
    private static let lock = NSLock()
    let directory: URL
    let bundledHelper: URL?
    init(directory: URL? = nil, bundledHelper: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AxisSalesCopilot/Credentials/v1", isDirectory: true)
        self.bundledHelper = bundledHelper ?? Bundle.main.resourceURL?.appendingPathComponent("Tools/AxisCredentials")
    }
    private func privatePath(_ url: URL, directory: Bool) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
              attributes[.ownerAccountID] as? UInt32 == getuid(),
              let mode = attributes[.posixPermissions] as? Int, mode & 0o077 == 0 else { throw CredentialFailure.path }
    }
    private func install(certificate: String) throws -> (URL, Data) {
        let fm = FileManager.default
        // Reject symlinks anywhere in the path, including pre-existing ancestors.
        var path = URL(fileURLWithPath: "/", isDirectory: true)
        for component in directory.pathComponents.dropFirst() {
            path.appendPathComponent(component, isDirectory: true)
            if fm.fileExists(atPath: path.path) {
                let attrs = try fm.attributesOfItem(atPath: path.path)
                let owner = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value
                let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
                guard owner == 0 || owner == getuid(),
                      mode & 0o022 == 0 || (owner == 0 && mode & 0o1000 != 0) else { throw CredentialFailure.path }
                guard try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else { throw CredentialFailure.path }
            } else { try fm.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        }
        try privatePath(directory, directory: true)
        let executable = directory.appendingPathComponent("AxisCredentials")
        let receipt = directory.appendingPathComponent("sha256")
        if !fm.fileExists(atPath: executable.path) {
            guard let bundledHelper else { throw CredentialFailure.path }
            _ = try CredentialIdentity.validateFile(bundledHelper, certificate: certificate)
            let staged = directory.appendingPathComponent(UUID().uuidString)
            defer { try? fm.removeItem(at: staged) }
            try fm.copyItem(at: bundledHelper, to: staged)
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: staged.path)
            _ = try CredentialIdentity.validateFile(staged, certificate: certificate)
            // link(2) refuses an existing destination atomically; never replace a pinned helper.
            do { try fm.linkItem(at: staged, to: executable) }
            catch { guard fm.fileExists(atPath: executable.path) else { throw error } }
        }
        try privatePath(executable, directory: false)
        let codeHash = try CredentialIdentity.validateFile(executable, certificate: certificate)
        let hash = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
        if fm.fileExists(atPath: receipt.path) {
            try privatePath(receipt, directory: false)
            guard try String(contentsOf: receipt, encoding: .utf8) == hash else { throw CredentialFailure.identity }
        } else {
            try Data(hash.utf8).write(to: receipt, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        }
        guard try CredentialIdentity.validateFile(executable, certificate: certificate) == codeHash else { throw CredentialFailure.identity }
        return (executable, codeHash)
    }
    func perform(_ operation: CredentialOperation, domain: CredentialDomain, data: Data? = nil) throws -> CredentialResponse {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard (data?.count ?? 0) <= 8_192 else { throw CredentialFailure.size }
        let certificate = try CredentialIdentity.ownCertificate()
        let (executable, expectedHash) = try install(certificate: certificate)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = []
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        // Do not allow an early child exit to terminate the app via SIGPIPE.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw CredentialFailure.protocolMismatch }
        try process.run()
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 22)
        timer.setEventHandler { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        timer.resume()
        defer {
            timer.cancel()
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        // Validate the running child as well as its on-disk image before sending any data.
        try CredentialIdentity.validateProcess(process.processIdentifier, identifier: CredentialIdentity.helper, certificate: certificate, expectedHash: expectedHash)
        let hello = try JSONDecoder().decode(CredentialResponse.self, from: CredentialFraming.read(output.fileHandleForReading))
        guard hello.version == 1, hello.status == 0, !hello.present, !hello.deleted, hello.data == nil, process.isRunning else { throw CredentialFailure.identity }
        try CredentialFraming.write(CredentialRequest(version: 1, domain: domain, operation: operation, data: data), to: input.fileHandleForWriting)
        try input.fileHandleForWriting.close()
        let result = try JSONDecoder().decode(CredentialResponse.self, from: CredentialFraming.read(output.fileHandleForReading))
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw CredentialFailure.storage(result.status == 0 ? errSecAuthFailed : result.status) }
        guard result.version == 1, (result.data?.count ?? 0) <= 8_192 else { throw CredentialFailure.protocolMismatch }
        guard result.status == 0 else { throw CredentialFailure.storage(result.status) }
        guard result.present || (!result.deleted && result.data == nil), !result.deleted || result.data == nil else { throw CredentialFailure.protocolMismatch }
        if operation == .read, result.present, !result.deleted, result.data == nil { throw CredentialFailure.protocolMismatch }
        return result
    }
}

/// New-store presence, including a tombstone, always takes precedence over legacy data.
enum CredentialVault {
    static func read(_ domain: CredentialDomain, bridge: CredentialBridge = CredentialBridge(), legacy: () throws -> Data?) throws -> Data? {
        let saved = try bridge.perform(.read, domain: domain)
        if saved.present { return saved.deleted ? nil : saved.data }
        guard let data = try legacy() else { return nil }
        _ = try bridge.perform(.migrate, domain: domain, data: data)
        let check = try bridge.perform(.read, domain: domain)
        guard check.present else { throw CredentialFailure.protocolMismatch }
        return check.deleted ? nil : check.data
    }
    static func save(_ data: Data, domain: CredentialDomain, bridge: CredentialBridge = CredentialBridge()) throws {
        _ = try bridge.perform(.write, domain: domain, data: data)
        let check = try bridge.perform(.read, domain: domain)
        guard check.present, !check.deleted, check.data == data else { throw CredentialFailure.protocolMismatch }
    }
    static func remove(_ domain: CredentialDomain, bridge: CredentialBridge = CredentialBridge()) throws {
        _ = try bridge.perform(.delete, domain: domain)
        let check = try bridge.perform(.read, domain: domain)
        guard check.present, check.deleted, check.data == nil else { throw CredentialFailure.protocolMismatch }
    }
}

extension CredentialFailure: LocalizedError {
    var errorDescription: String? {
        L10n.string("Защищённое хранилище недоступно. Разблокируйте Mac и проверьте подключение повторно.")
    }
}
