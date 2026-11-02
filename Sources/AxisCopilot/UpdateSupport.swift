import Foundation
import Security
import CryptoKit

struct UpdateFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Only application bundles signed by the current certificate can replace this app.
/// Certificate hashes are identifiers, not private key material.
enum UpdateValidation {
    static let identifier = "ru.axisconsult.SalesCopilot"

    static func version(_ value: String) throws -> [Int] {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { throw UpdateFailure("Неверный номер версии.") }
        let numbers = try parts.map { part -> Int in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part), number >= 0 else { throw UpdateFailure("Неверный номер версии.") }
            return number
        }
        return numbers + Array(repeating: 0, count: 4 - numbers.count)
    }

    static func isNewer(_ candidate: String, than installed: String) throws -> Bool {
        let a = try version(candidate), b = try version(installed)
        return b.lexicographicallyPrecedes(a)
    }

    static func certificate(_ url: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateFailure("Не удалось прочитать подпись приложения.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
            throw UpdateFailure("Подпись приложения повреждена или отсутствует.")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else {
            throw UpdateFailure("Нужна постоянная подпись. Ad-hoc сборка не поддерживает безопасные обновления.")
        }
        return Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
    }

    static func metadata(_ url: URL) throws -> [String: Any] {
        guard url.pathExtension == "app", !((try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink ?? true),
              let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == identifier,
              info["CFBundlePackageType"] as? String == "APPL",
              info["CFBundleExecutable"] as? String == "AxisCopilot" else {
            throw UpdateFailure("Выберите комплект AxisCopilot.app с правильным идентификатором.")
        }
        return info
    }

    static func validate(_ candidate: URL, current: URL, pinnedCertificate: String? = nil) throws {
        let old = try metadata(current), new = try metadata(candidate)
        let signer = try certificate(current)
        if let pinnedCertificate, signer != pinnedCertificate { throw UpdateFailure("Подпись установленной версии изменилась.") }
        guard try certificate(candidate) == signer else { throw UpdateFailure("Обновление подписано другим сертификатом.") }
        guard let oldVersion = old["CFBundleVersion"] as? String, let newVersion = new["CFBundleVersion"] as? String,
              try isNewer(newVersion, than: oldVersion) else { throw UpdateFailure("Нужна сборка с более новым номером версии.") }
        let binary = candidate.appendingPathComponent("Contents/MacOS/AxisCopilot")
        let executable = binary.resolvingSymlinksInPath()
        guard executable.path.hasPrefix(candidate.resolvingSymlinksInPath().path + "/"),
              try command("/usr/bin/lipo", ["-archs", binary.path]).split(separator: " ").contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64" }) else {
            throw UpdateFailure("В комплекте нет исполняемой версии для Apple Silicon.")
        }
    }

    @discardableResult static func command(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure("Не удалось выполнить проверку комплекта.") }
        return String(decoding: data, as: UTF8.self)
    }
}

enum UpdateInstaller {
    /// All paths live on one volume. Backup survives every unsuccessful replacement.
    static func replace(staged: URL, destination: URL, backup: URL, validate: (URL) throws -> Void,
                        launch: (URL) async throws -> Void) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: backup.path) else { throw UpdateFailure("Резервная копия уже существует.") }
        try validate(staged)
        try fm.moveItem(at: destination, to: backup)
        do {
            try fm.moveItem(at: staged, to: destination)
            try validate(destination)
            try await launch(destination)
        } catch {
            // Return failed candidate to staging rather than destroying any bundle.
            if fm.fileExists(atPath: destination.path) { try fm.moveItem(at: destination, to: staged) }
            try fm.moveItem(at: backup, to: destination)
            throw error
        }
        // Keep the last working bundle until the next explicit update/cleanup.
    }
}
