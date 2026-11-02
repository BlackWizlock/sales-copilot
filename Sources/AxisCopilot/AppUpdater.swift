import AppKit
import Combine
import Foundation

@MainActor final class AppUpdater: ObservableObject {
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var isUpdating = false
    private(set) var allowsTermination = false

    func chooseUpdate(currentlyBusy: Bool) {
        guard !isUpdating else { return }
        error = nil
        guard !currentlyBusy else {
            error = "Завершите запись и дождитесь обработки встречи перед обновлением."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Выберите подписанное обновление AxisCopilot.app"
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let current = Bundle.main.bundleURL.standardizedFileURL
        let allowed = ["/Applications/AxisCopilot.app", NSHomeDirectory() + "/Applications/AxisCopilot.app"]
        guard allowed.contains(current.path), current.resolvingSymlinksInPath() == current else {
            error = "Сначала установите AxisCopilot.app в папку «Программы»."
            return
        }
        isUpdating = true; status = "Проверяем и подготавливаем обновление…"
        Task {
            var workspace: URL?
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try Self.prepare(source: source, current: current)
                }.value
                workspace = prepared.workspace
                let alert = NSAlert()
                alert.messageText = "Установить обновление и перезапустить приложение?"
                alert.informativeText = "Подпись и версия проверены. Записи сохранятся. Предыдущая версия останется в резервной копии."
                alert.addButton(withTitle: "Установить и перезапустить"); alert.addButton(withTitle: "Отмена")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    try? FileManager.default.removeItem(at: prepared.workspace)
                    isUpdating = false; status = "Обновление отменено."
                    return
                }
                let helper = Process()
                helper.executableURL = prepared.workspace.appendingPathComponent("AxisUpdater")
                helper.arguments = ["install", current.path, prepared.workspace.path,
                                    prepared.workspace.appendingPathComponent("Previous.app").path,
                                    String(ProcessInfo.processInfo.processIdentifier), prepared.signer]
                helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
                try helper.run()
                status = "Приложение завершает работу для установки обновления…"
                allowsTermination = true
                NSApplication.shared.terminate(nil)
            } catch {
                if let workspace { try? FileManager.default.removeItem(at: workspace) }
                self.error = error.localizedDescription; status = "Обновление не установлено."; isUpdating = false
            }
        }
    }

    private nonisolated static func prepare(source: URL, current: URL) throws -> (workspace: URL, signer: String) {
        let fm = FileManager.default
        guard source.standardizedFileURL != current, fm.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw UpdateFailure("Нет доступа для обновления в этой папке. Установите приложение в ~/Applications или обратитесь к администратору.")
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
            guard try UpdateValidation.certificate(helper) == signer else { throw UpdateFailure("Подпись помощника обновления не совпадает.") }
            let copy = directory.appendingPathComponent("AxisUpdater")
            try fm.copyItem(at: helper, to: copy)
            guard try UpdateValidation.certificate(copy) == signer else { throw UpdateFailure("Копия помощника обновления повреждена.") }
            return (directory, signer)
        } catch { try? fm.removeItem(at: directory); throw error }
    }
}
