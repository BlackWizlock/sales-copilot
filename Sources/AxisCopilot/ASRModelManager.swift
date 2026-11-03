import Foundation
import Combine
import CryptoKit
import CopilotCore

@MainActor final class ASRModelManager: ObservableObject {
    let models = ASRCatalog.models
    @Published private(set) var selectedID = UserDefaults.standard.string(forKey: "asrModelID") ?? "whisper-small"
    @Published var language = UserDefaults.standard.string(forKey: "asrLanguage") ?? "ru" {
        didSet { if ["ru", "en", "auto"].contains(language) { UserDefaults.standard.set(language, forKey: "asrLanguage") } }
    }
    @Published private(set) var downloadID: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var installedPaths: [String: URL] = [:]
    private var operation: Task<Void, Never>?
    private(set) static var verifiedPaths: [String: URL] = [:]
    nonisolated static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AxisSalesCopilot/Models/ASR") }
    nonisolated static var sharedParakeet: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml") }
    var canReuseParakeet: Bool { FileManager.default.fileExists(atPath: Self.sharedParakeet.path) }

    init() {
        Task {
            for model in models {
                let folder = Self.root.appendingPathComponent(model.id)
                if let receipt = try? Data(contentsOf: folder.appendingPathComponent(".axis-asr-manifest.json")),
                   let assets = try? JSONDecoder().decode([ASRArtifact].self, from: receipt) {
                    let verified = await Task.detached(priority: .utility) { (try? Self.verify(assets, in: folder)) != nil }.value
                    if verified {
                        let location = model.filename.map { folder.appendingPathComponent($0) } ?? folder
                        installedPaths[model.id] = location; Self.verifiedPaths[model.id] = location
                    }
                }
            }
            let reuseReceipt = Self.root.appendingPathComponent("parakeet-v3-reuse.json")
            if let receipt = try? Data(contentsOf: reuseReceipt), let assets = try? JSONDecoder().decode([ASRArtifact].self, from: receipt),
               await Task.detached(priority: .utility, operation: { (try? Self.verify(assets, in: Self.sharedParakeet)) != nil }).value {
                installedPaths["parakeet-v3"] = Self.sharedParakeet; Self.verifiedPaths["parakeet-v3"] = Self.sharedParakeet
            }
            await restoreSmallFallback()
        }
    }
    private func restoreSmallFallback() async {
        let small = LocalTranscriber.defaultModel
        guard installedPaths["whisper-small"] == nil else { return }
        let checked = await Task.detached(priority: .utility) {
            guard small.standardizedFileURL == small.resolvingSymlinksInPath(), let data = try? Data(contentsOf: small, options: .mappedIfSafe) else { return false }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
        }.value
        if checked { installedPaths["whisper-small"] = small; Self.verifiedPaths["whisper-small"] = small }
    }
    func canRemove(_ model: ASRModelDescriptor) -> Bool {
        guard model.id != selectedID, downloadID != model.id, let location = installedPaths[model.id] else { return false }
        let directory = Self.root.appendingPathComponent(model.id)
        let expected = model.filename.map { directory.appendingPathComponent($0) } ?? directory
        return location.standardizedFileURL == expected.standardizedFileURL && Self.root.standardizedFileURL == Self.root.resolvingSymlinksInPath() && directory.standardizedFileURL == directory.resolvingSymlinksInPath()
    }
    func remove(_ model: ASRModelDescriptor, busy: Bool) {
        do {
            guard downloadID != model.id, let location = installedPaths[model.id] else { throw UpdateFeedError(L10n.string("Удалять можно только неиспользуемую копию модели, загруженную этим приложением.")) }
            let directory = try ASRCatalog.removableDirectory(model: model, installed: location, root: Self.root, selectedID: selectedID, busy: busy)
            try FileManager.default.removeItem(at: directory)
            installedPaths.removeValue(forKey: model.id); Self.verifiedPaths.removeValue(forKey: model.id)
            error = nil; status = L10n.format("Модель %@ удалена. Текущая модель сохранена.", String(describing: model.name))
            if model.id == "whisper-small" { Task { await restoreSmallFallback() } }
        } catch { self.error = L10n.error(error) }
    }
    func select(_ model: ASRModelDescriptor, busy: Bool) {
        guard !busy else { error = L10n.string("Завершите запись и обработку перед сменой модели."); return }
        guard let path = installedPaths[model.id] else { error = L10n.string("Сначала загрузите и проверьте модель."); return }
        selectedID = model.id
        UserDefaults.standard.set(model.id, forKey: "asrModelID")
        UserDefaults.standard.set(path.path, forKey: "asrModelPath")
        status = L10n.format("Выбрана модель %@.", String(describing: model.name)); error = nil
    }
    func cancelDownload() { operation?.cancel() }
    func download(_ model: ASRModelDescriptor) { start(model, reuse: false) }
    func reuseParakeet() { if let model = models.first(where: { $0.engine == .parakeet }) { start(model, reuse: true) } }

    private func start(_ model: ASRModelDescriptor, reuse: Bool) {
        guard downloadID == nil else { return }
        downloadID = model.id; progress = 0; error = nil
        status = reuse ? L10n.string("Проверяем имеющиеся файлы Parakeet…") : L10n.string("Получаем список файлов модели…")
        operation = Task { [self] in
            var staging: URL?
            defer { if let staging { try? FileManager.default.removeItem(at: staging) }; downloadID = nil; operation = nil }
            do {
                let assets = try await Self.manifest(model)
                try Task.checkCancellation()
                if reuse {
                    try await Task.detached(priority: .utility) { try Self.verify(assets, in: Self.sharedParakeet) }.value
                    try Task.checkCancellation()
                    try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try JSONEncoder().encode(assets).write(to: Self.root.appendingPathComponent("parakeet-v3-reuse.json"), options: .atomic)
                    installedPaths[model.id] = Self.sharedParakeet; Self.verifiedPaths[model.id] = Self.sharedParakeet
                    status = L10n.string("Модель проверена. Можно выбрать её для следующей записи.")
                    progress = 1; return
                }
                try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let directory = Self.root.appendingPathComponent(".download-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                staging = directory
                let total = assets.reduce(Int64(0)) { $0 + $1.size }
                var completed: Int64 = 0
                for asset in assets {
                    try Task.checkCancellation()
                    status = L10n.format("Загружаем %@…", String(describing: model.name))
                    let previous = completed
                    let temp = try await ASRFileDownload.fetch(asset.url, limit: asset.size) { [weak self] fraction in
                        Task { @MainActor in self?.progress = Double(previous) / Double(total) + fraction * Double(asset.size) / Double(total) }
                    }
                    defer { try? FileManager.default.removeItem(at: temp) }
                    try await Task.detached(priority: .utility) { try Self.verify(asset, file: temp) }.value
                    let target = directory.appendingPathComponent(asset.path)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try FileManager.default.moveItem(at: temp, to: target)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                    completed += asset.size
                }
                try Task.checkCancellation()
                try JSONEncoder().encode(assets).write(to: directory.appendingPathComponent(".axis-asr-manifest.json"), options: .atomic)
                let final = Self.root.appendingPathComponent(model.id)
                guard !FileManager.default.fileExists(atPath: final.path) else { throw UpdateFeedError(L10n.string("Модель уже установлена. Существующие файлы сохранены.")) }
                try FileManager.default.moveItem(at: directory, to: final)
                staging = nil
                let location = model.filename.map { final.appendingPathComponent($0) } ?? final
                installedPaths[model.id] = location; Self.verifiedPaths[model.id] = location
                status = L10n.string("Модель загружена и проверена. Выберите её для следующей записи."); progress = 1
            } catch {
                if Task.isCancelled { status = L10n.string("Загрузка отменена. Прежняя модель сохранена.") }
                else { self.error = L10n.error(error); status = L10n.string("Модель не установлена. Прежняя модель сохранена.") }
            }
        }
    }

    nonisolated static func verifiedSharedParakeet() async throws -> (count: Int, revision: String, bytes: Int64) {
        let descriptor = ASRCatalog.models.first { $0.engine == .parakeet }!
        let assets = try await manifest(descriptor)
        try await Task.detached(priority: .utility) { try verify(assets, in: sharedParakeet) }.value
        let revision = assets.first?.url.pathComponents.drop(while: { $0 != "resolve" }).dropFirst().first ?? "unknown"
        return (assets.count, revision, assets.reduce(0) { $0 + $1.size })
    }

    private nonisolated static func manifest(_ model: ASRModelDescriptor) async throws -> [ASRArtifact] {
        func json(_ address: String) async throws -> Data {
            let file = try await ASRFileDownload.fetch(URL(string: address)!, limit: 4_000_000)
            defer { try? FileManager.default.removeItem(at: file) }
            return try Data(contentsOf: file)
        }
        let revision = try ASRCatalog.revision(from: await json("https://huggingface.co/api/models/\(model.repository)/revision/main"))
        let data = try await json("https://huggingface.co/api/models/\(model.repository)/tree/\(revision)?recursive=true&limit=1000")
        return try ASRCatalog.artifacts(from: data, model: model, revision: revision)
    }
    private nonisolated static func verify(_ assets: [ASRArtifact], in folder: URL) throws {
        guard !assets.isEmpty else { throw UpdateFeedError(L10n.string("Пустой список файлов модели.")) }
        for asset in assets { try verify(asset, file: folder.appendingPathComponent(asset.path)) }
    }
    private nonisolated static func verify(_ asset: ASRArtifact, file: URL) throws {
        try ASRCatalog.safePath(asset.path)
        guard file.standardizedFileURL == file.resolvingSymlinksInPath(),
              try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]).isRegularFile == true else { throw UpdateFeedError(L10n.string("Недопустимый файл модели.")) }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count == asset.size else { throw UpdateFeedError(L10n.string("Размер файла модели не совпадает.")) }
        let digest: String
        if asset.algorithm == "sha256" { digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        else if asset.algorithm == "git-sha1" {
            var hash = Insecure.SHA1(); hash.update(data: Data("blob \(data.count)\0".utf8)); hash.update(data: data)
            digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        } else { throw UpdateFeedError(L10n.string("Неизвестный алгоритм проверки модели.")) }
        guard digest == asset.checksum else { throw UpdateFeedError(L10n.string("Контрольная сумма файла модели не совпадает.")) }
    }
}

private final class ASRFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int64
    let progress: @Sendable (Double) -> Void
    init(limit: Int64, progress: @escaping @Sendable (Double) -> Void) { self.limit = limit; self.progress = progress }
    static func fetch(_ url: URL, limit: Int64, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard url.scheme == "https", url.user == nil, url.password == nil else { throw UpdateFeedError(L10n.string("Нужен HTTPS адрес модели.")) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 1800
        config.urlCache = nil; config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let delegate = ASRFileDownload(limit: limit, progress: progress)
        let (temporary, response) = try await session.download(for: URLRequest(url: url), delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.url?.scheme == "https",
              (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= limit else { throw UpdateFeedError(L10n.string("Не удалось скачать файл модели в пределах разрешённого размера.")) }
        let target = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("axis-asr-" + UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.user == nil && request.url?.password == nil ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel(); return }
        progress(min(1, Double(totalBytesWritten) / Double(max(1, limit))))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
