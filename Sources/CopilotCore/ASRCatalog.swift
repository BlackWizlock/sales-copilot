import Foundation

public enum ASREngine: String, Codable { case whisper, parakeet }
public struct ASRModelDescriptor: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let engine: ASREngine
    public let repository: String
    public let filename: String?
    public let approximateGB: Double
    public let languages: [String]
    public var requiredRoots: [String] {
        if let filename { return [filename] }
        return ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc", "parakeet_vocab.json"]
    }
}
public struct ASRArtifact: Codable, Equatable {
    public let path: String
    public let size: Int64
    public let checksum: String
    public let algorithm: String
    public let url: URL
}
public enum ASRCatalog {
    public static let models = [
        ASRModelDescriptor(id: "whisper-small", name: "Whisper Small", engine: .whisper, repository: "ggerganov/whisper.cpp", filename: "ggml-small.bin", approximateGB: 0.49, languages: ["ru", "en"]),
        ASRModelDescriptor(id: "whisper-medium", name: "Whisper Medium", engine: .whisper, repository: "ggerganov/whisper.cpp", filename: "ggml-medium.bin", approximateGB: 1.53, languages: ["ru", "en"]),
        ASRModelDescriptor(id: "whisper-turbo", name: "Whisper Large v3 Turbo", engine: .whisper, repository: "ggerganov/whisper.cpp", filename: "ggml-large-v3-turbo.bin", approximateGB: 1.62, languages: ["ru", "en"]),
        ASRModelDescriptor(id: "parakeet-v3", name: "Parakeet TDT 0.6B v3", engine: .parakeet, repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml", filename: nil, approximateGB: 0.49, languages: ["ru", "en"])
    ]
    /// Return only an inactive app-owned directory after checking the full tree.
    /// Bundled models, shared caches and symbolic links are never deletion candidates.
    public static func removableDirectory(model: ASRModelDescriptor, installed: URL, root: URL, selectedID: String, busy: Bool) throws -> URL {
        guard !busy, selectedID != model.id else { throw UpdateFeedError("Сначала выберите другую модель и завершите обработку встречи.") }
        let directory = root.appendingPathComponent(model.id).standardizedFileURL
        let expected = model.filename.map { directory.appendingPathComponent($0) } ?? directory
        guard models.contains(model), installed.standardizedFileURL == expected, directory.deletingLastPathComponent() == root.standardizedFileURL,
              root.standardizedFileURL == root.resolvingSymlinksInPath(), directory == directory.resolvingSymlinksInPath(),
              try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false,
              try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else {
            throw UpdateFeedError("Удалять можно только неиспользуемую копию модели, загруженную этим приложением.")
        }
        var enumerationFailed = false
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, errorHandler: { _, _ in enumerationFailed = true; return false }) else {
            throw UpdateFeedError("Не удалось безопасно проверить каталог модели.")
        }
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink == false, values.isRegularFile == true || values.isDirectory == true,
                  file.standardizedFileURL == file.resolvingSymlinksInPath(), file.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else {
                throw UpdateFeedError("Каталог модели содержит ссылку или неподдерживаемый файл. Удаление отменено.")
            }
        }
        guard !enumerationFailed else { throw UpdateFeedError("Не удалось безопасно проверить каталог модели.") }
        return directory
    }

    private static func hex(_ value: String, count: Int) -> Bool { value.count == count && value.allSatisfy { $0.isASCII && $0.isHexDigit } }
    public static func revision(from data: Data) throws -> String {
        struct Info: Decodable { let sha: String }
        let value = try JSONDecoder().decode(Info.self, from: data).sha
        guard hex(value, count: 40) else { throw UpdateFeedError("Не удалось закрепить версию модели.") }
        return value
    }
    public static func safePath(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(""), !parts.contains(".."), !parts.contains("."), !value.contains("\\"), !value.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw UpdateFeedError("Недопустимый путь файла модели.")
        }
    }
    public static func artifacts(from data: Data, model: ASRModelDescriptor, revision: String) throws -> [ASRArtifact] {
        struct Entry: Decodable {
            struct LFS: Decodable { let oid: String; let size: Int64 }
            let type: String; let path: String; let size: Int64?; let oid: String?; let lfs: LFS?
        }
        guard hex(revision, count: 40), data.count < 4_000_000 else { throw UpdateFeedError("Некорректный список файлов модели.") }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        guard entries.count < 1000 else { throw UpdateFeedError("Список файлов модели требует обновления приложения.") }
        var results: [ASRArtifact] = [], seen = Set<String>(), total: Int64 = 0
        for entry in entries where entry.type == "file" && model.requiredRoots.contains(where: { entry.path == $0 || entry.path.hasPrefix($0 + "/") }) {
            try safePath(entry.path)
            let digest = entry.lfs?.oid ?? entry.oid ?? "", size = entry.lfs?.size ?? entry.size ?? 0
            guard seen.insert(entry.path).inserted, size > 0, size <= 3_000_000_000, hex(digest, count: entry.lfs == nil ? 40 : 64) else {
                throw UpdateFeedError("Для файла модели нет корректной контрольной суммы или размера.")
            }
            total += size
            guard total <= 5_000_000_000 else { throw UpdateFeedError("Модель превышает допустимый размер.") }
            let base = URL(string: "https://huggingface.co/\(model.repository)/resolve/\(revision)/")!
            results.append(ASRArtifact(path: entry.path, size: size, checksum: digest.lowercased(), algorithm: entry.lfs == nil ? "git-sha1" : "sha256", url: base.appendingPathComponent(entry.path)))
        }
        guard model.requiredRoots.allSatisfy({ root in results.contains { $0.path == root || $0.path.hasPrefix(root + "/") } }) else {
            throw UpdateFeedError("В репозитории модели отсутствуют необходимые файлы.")
        }
        return results
    }
}
