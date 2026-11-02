import Foundation
import AppKit
import Darwin

@main struct UpdateHelper {
    @MainActor static func launch(_ app: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: app, configuration: config) { application, error in
                if let error { continuation.resume(throwing: error) }
                else if application != nil { continuation.resume() }
                else { continuation.resume(throwing: UpdateFailure("Система не подтвердила запуск приложения.")) }
            }
        }
    }
    @MainActor static func main() async {
        var exitedParent = false
        var previousVersion: String?
        do {
            let args = CommandLine.arguments
            if args.count == 4, args[1] == "validate" {
                try UpdateValidation.validate(URL(fileURLWithPath: args[3]), current: URL(fileURLWithPath: args[2]))
                return
            }
            guard args.count == 7, args[1] == "install", let pid = Int32(args[5]), pid > 1,
                  args[6].count == 40, args[6].allSatisfy({ $0.isHexDigit }) else { throw UpdateFailure("Неверные параметры обновления.") }
            let destination = URL(fileURLWithPath: args[2]).standardizedFileURL
            let allowed = ["/Applications/AxisCopilot.app", NSHomeDirectory() + "/Applications/AxisCopilot.app"]
            guard allowed.contains(destination.path), destination.resolvingSymlinksInPath() == destination else {
                throw UpdateFailure("Обновление доступно только из папки «Программы».")
            }
            let workspace = URL(fileURLWithPath: args[3]).standardizedFileURL
            let staged = workspace.appendingPathComponent("AxisCopilot.app")
            guard workspace.deletingLastPathComponent() == destination.deletingLastPathComponent(),
                  workspace.lastPathComponent.hasPrefix(".axis-update-"), workspace.resolvingSymlinksInPath() == workspace,
                  args[4] == workspace.appendingPathComponent("Previous.app").path else { throw UpdateFailure("Неверная папка подготовки.") }
            // Never replace a live process, including a delayed or cancelled termination.
            let deadline = Date().addingTimeInterval(120)
            while kill(pid, 0) == 0 || errno == EPERM {
                guard Date() < deadline else { throw UpdateFailure("Приложение не завершилось. Обновление отменено.") }
                try await Task.sleep(for: .milliseconds(250))
            }
            exitedParent = true
            let currentVersion = (try UpdateValidation.metadata(destination))["CFBundleVersion"] as? String
            previousVersion = currentVersion
            try UpdateValidation.validate(staged, current: destination, pinnedCertificate: args[6])
            try await UpdateInstaller.replace(staged: staged, destination: destination, backup: URL(fileURLWithPath: args[4]), validate: { app in
                guard try UpdateValidation.certificate(app) == args[6],
                      let version = try UpdateValidation.metadata(app)["CFBundleVersion"] as? String,
                      let currentVersion, try UpdateValidation.isNewer(version, than: currentVersion) else { throw UpdateFailure("Повторная проверка обновления не пройдена.") }
            }, launch: launch)
            try "Обновление установлено. Резервная копия: \(args[4])".write(to: workspace.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        } catch {
            let message = "Обновление не установлено: \(error.localizedDescription)"
            if CommandLine.arguments.count == 7 {
                let workspace = URL(fileURLWithPath: CommandLine.arguments[3])
                let destination = URL(fileURLWithPath: CommandLine.arguments[2])
                if exitedParent, let previousVersion,
                   (try? UpdateValidation.metadata(destination)["CFBundleVersion"] as? String) == previousVersion,
                   (try? UpdateValidation.certificate(destination)) == CommandLine.arguments[6] {
                    try? await launch(destination)
                }
                // A visible failure survives helper exit. No automatic capture restart.
                try? message.write(to: workspace.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                let alert = NSAlert(); alert.messageText = "Не удалось обновить Axis Суфлёр"; alert.informativeText = message + "\nРезервная копия, если создана: " + CommandLine.arguments[4]
                alert.runModal()
            } else { fputs(message + "\n", stderr) }
            exit(1)
        }
    }
}
