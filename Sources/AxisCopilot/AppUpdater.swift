import AppKit
import Combine
import Foundation
import CryptoKit
import CopilotCore

@MainActor final class AppUpdater: ObservableObject {
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var isUpdating = false
    @Published private(set) var isInstalling = false
    private(set) var allowsTermination = false
    @Published private(set) var available: UpdateRelease?
    @Published private(set) var isChecking = false
    private var busy = false
    private var monitor: Task<Void, Never>?

    init() {
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForUpdates(silent: true)
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    deinit { monitor?.cancel() }
    func setBusy(_ value: Bool) { busy = value }

    func checkForUpdates(silent: Bool = false) async {
        guard !isChecking, !isUpdating else { return }
        let address = UserDefaults.standard.string(forKey: "axisUpdateFeedURL") ?? Bundle.main.object(forInfoDictionaryKey: "AxisUpdateFeedURL") as? String
        guard let address, let url = URL(string: address), UpdateRelease.secureURL(url) else {
            if !silent { error = L10n.string("Сервер обновлений ещё не настроен владельцем.") }
            return
        }
        isChecking = true
        defer { isChecking = false }
        do {
            let file = try await CappedUpdateDownload.fetch(url, limit: 65_536, timeout: 30, isManifest: true)
            defer { try? FileManager.default.removeItem(at: file) }
            let release = try UpdateRelease.decode(Data(contentsOf: file), feedURL: url)
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
            available = try release.isEligible(installedBuild: installed, operatingSystem: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") ? release : nil
            if available != nil { status = L10n.format("Доступна новая версия %@ (%@).", String(describing: release.version), String(describing: release.build)) }
            else if !silent || status.hasPrefix(L10n.string("Доступна новая версия")) { status = L10n.string("Установлена последняя совместимая версия.") }
            error = nil
        } catch { if !silent { self.error = L10n.string(L10n.error(error)) } }
    }

    func installAvailable(currentlyBusy: Bool) {
        guard let release = available, !isUpdating else { return }
        busy = currentlyBusy
        guard !busy else { error = L10n.string("Завершите запись и обработку встречи перед обновлением."); return }
        isUpdating = true; error = nil; status = L10n.string("Скачиваем обновление…")
        Task {
            var downloaded: URL?
            var extracted: URL?
            do {
                let file = try await CappedUpdateDownload.fetch(release.url, limit: release.size, timeout: 600)
                downloaded = file
                let source = try await Task.detached(priority: .utility) {
                    let data = try Data(contentsOf: file, options: .mappedIfSafe)
                    guard data.count == release.size,
                          SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == release.sha256.lowercased() else {
                        throw UpdateFailure(L10n.string("Размер или контрольная сумма обновления не совпадает."))
                    }
                    try UpdateArchive.validate(data)
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("axis-extract-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    do {
                        try UpdateValidation.command("/usr/bin/ditto", ["-x", "-k", file.path, folder.path])
                        let app = folder.appendingPathComponent("AxisCopilot.app")
                        let metadata = try UpdateValidation.metadata(app)
                        guard metadata["CFBundleVersion"] as? String == release.build,
                              metadata["CFBundleShortVersionString"] as? String == release.version else { throw UpdateFailure(L10n.string("Версия в архиве не совпадает с описанием обновления.")) }
                        return app
                    } catch { try? FileManager.default.removeItem(at: folder); throw error }
                }.value
                extracted = source.deletingLastPathComponent()
                guard !busy else { throw UpdateFailure(L10n.string("Завершите запись и обработку встречи перед установкой.")) }
                isUpdating = false; isInstalling = false
                install(source: source, currentlyBusy: busy, cleanupDirectory: extracted)
            } catch { self.error = L10n.error(error); status = L10n.string("Обновление не установлено."); isUpdating = false; isInstalling = false }
            // install copies source in its detached task; extraction is removed by install after prepare.
            if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
            if isUpdating == false, let extracted { try? FileManager.default.removeItem(at: extracted) }
        }
    }

    private var updatePanel: NSOpenPanel?
    func chooseUpdate(currentlyBusy: Bool) {
        guard !isUpdating, updatePanel == nil else { return }
        error = nil
        guard !currentlyBusy else {
            error = L10n.string("Завершите запись и дождитесь обработки встречи перед обновлением.")
            return
        }
        let panel = NSOpenPanel()
        panel.title = L10n.string("Выберите подписанное обновление AxisCopilot.app")
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.applicationBundle]
        updatePanel = panel
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.updatePanel = nil
            guard response == .OK, let source = panel.url else { return }
            self.install(source: source, currentlyBusy: self.busy)
        }
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else { panel.begin(completionHandler: completion) }
    }

    private func install(source: URL, currentlyBusy: Bool, cleanupDirectory: URL? = nil) {
        guard !isUpdating, !currentlyBusy else { return }
        let current = Bundle.main.bundleURL.standardizedFileURL
        let allowed = ["/Applications/AxisCopilot.app", NSHomeDirectory() + "/Applications/AxisCopilot.app"]
        guard allowed.contains(current.path), current.resolvingSymlinksInPath() == current else {
            error = L10n.string("Сначала установите AxisCopilot.app в папку «Программы».")
            return
        }
        isUpdating = true; isInstalling = true; status = L10n.string("Проверяем и подготавливаем обновление…")
        Task {
            var workspace: URL?
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    defer {
                        if let cleanupDirectory { try? FileManager.default.removeItem(at: cleanupDirectory) }
                    }
                    return try Self.prepare(source: source, current: current)
                }.value
                workspace = prepared.workspace
                guard !busy else { throw UpdateFailure(L10n.string("Завершите запись и обработку встречи перед установкой.")) }
                let alert = NSAlert()
                alert.messageText = L10n.string("Установить обновление и перезапустить приложение?")
                alert.informativeText = L10n.string("Подпись и версия проверены. Записи сохранятся. Предыдущая версия останется в резервной копии.")
                alert.addButton(withTitle: L10n.string("Установить и перезапустить")); alert.addButton(withTitle: L10n.string("Отмена"))
                guard alert.runModal() == .alertFirstButtonReturn else {
                    try? FileManager.default.removeItem(at: prepared.workspace)
                    isUpdating = false; isInstalling = false; status = L10n.string("Обновление отменено.")
                    return
                }
                guard !busy else { throw UpdateFailure(L10n.string("Завершите запись и обработку встречи перед установкой.")) }
                let helper = Process()
                helper.executableURL = prepared.workspace.appendingPathComponent("AxisUpdater")
                helper.arguments = ["install", current.path, prepared.workspace.path,
                                    prepared.workspace.appendingPathComponent("Previous.app").path,
                                    String(ProcessInfo.processInfo.processIdentifier), prepared.signer]
                helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
                try helper.run()
                status = L10n.string("Приложение завершает работу для установки обновления…")
                allowsTermination = true
                NSApplication.shared.terminate(nil)
            } catch {
                if let workspace { try? FileManager.default.removeItem(at: workspace) }
                self.error = L10n.error(error); status = L10n.string("Обновление не установлено."); isUpdating = false; isInstalling = false
            }
        }
    }

    private nonisolated static func prepare(source: URL, current: URL) throws -> (workspace: URL, signer: String) {
        let fm = FileManager.default
        guard source.standardizedFileURL != current, fm.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw UpdateFailure(L10n.string("Нет доступа для обновления в этой папке. Установите приложение в ~/Applications или обратитесь к администратору."))
        }
        try UpdateValidation.validate(source, current: current)
        let signer = try UpdateValidation.certificate(current)
        let directory = current.deletingLastPathComponent().appendingPathComponent(".axis-update-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let stage = directory.appendingPathComponent("AxisCopilot.app")
            try fm.copyItem(at: source, to: stage)
            try UpdateValidation.validate(stage, current: current, pinnedCertificate: signer)
            let helper = current.appendingPathComponent("Contents/Resources/Tools/AxisUpdater")
            guard try UpdateValidation.certificate(helper) == signer else { throw UpdateFailure(L10n.string("Подпись помощника обновления не совпадает.")) }
            let copy = directory.appendingPathComponent("AxisUpdater")
            try fm.copyItem(at: helper, to: copy)
            guard try UpdateValidation.certificate(copy) == signer else { throw UpdateFailure(L10n.string("Копия помощника обновления повреждена.")) }
            return (directory, signer)
        } catch { try? fm.removeItem(at: directory); throw error }
    }
}

/// Ephemeral streaming downloads have byte and time ceilings; redirects cannot leave the HTTPS origin.
private final class CappedUpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let origin: URL
    private let limit: Int64
    private let isManifest: Bool
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: URL?
    private var failure: Error?
    private var session: URLSession?
    private init(_ url: URL, limit: Int64, isManifest: Bool) { origin = url; self.limit = limit; self.isManifest = isManifest }

    static func fetch(_ url: URL, limit: Int64, timeout: TimeInterval, isManifest: Bool = false) async throws -> URL {
        guard UpdateRelease.secureURL(url) else { throw UpdateFailure(L10n.string("Нужен защищённый адрес обновления.")) }
        let download = CappedUpdateDownload(url, limit: limit, isManifest: isManifest)
        return try await withCheckedThrowingContinuation { continuation in
            download.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = min(60, timeout); config.timeoutIntervalForResource = timeout
            config.urlCache = nil; config.httpCookieStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config, delegate: download, delegateQueue: nil)
            download.session = session
            session.downloadTask(with: url).resume()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, UpdateRelease.secureURL(url), url.host == origin.host, url.port == origin.port else {
            failure = UpdateFailure(L10n.string("Сервер перенаправил обновление на другой адрес.")); completionHandler(nil); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            failure = UpdateFailure(L10n.string("Обновление превышает допустимый размер.")); downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw UpdateFailure(L10n.string("Сервер вернул некорректное обновление.")) }
            try UpdateHTTPResponse.validate(status: response.statusCode, isManifest: isManifest)
            guard let url = response.url, UpdateRelease.secureURL(url), url.host == origin.host, url.port == origin.port,
                  (try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= limit else {
                throw UpdateFailure(L10n.string("Сервер вернул некорректное обновление."))
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("axis-download-" + UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: file)
            result = file
        } catch { failure = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure = failure ?? error { if let result { try? FileManager.default.removeItem(at: result) }; continuation?.resume(throwing: failure) }
        else if let result { continuation?.resume(returning: result) }
        else { continuation?.resume(throwing: UpdateFailure(L10n.string("Не удалось скачать обновление."))) }
        continuation = nil; session.finishTasksAndInvalidate(); self.session = nil
    }
}
