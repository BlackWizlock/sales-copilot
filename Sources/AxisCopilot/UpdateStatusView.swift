import SwiftUI

struct UpdateStatusView: View {
    @ObservedObject var updater: AppUpdater
    let busy: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if updater.available != nil {
                Button(L10n.string("Доступно обновление"), systemImage: "arrow.down.app") { updater.installAvailable(currentlyBusy: busy) }
                    .disabled(busy || updater.isUpdating)
            } else {
                Menu(L10n.string("Обновления")) {
                    Button(L10n.string("Проверить обновления")) { Task { await updater.checkForUpdates() } }.disabled(updater.isChecking || updater.isUpdating)
                    Button(L10n.string("Установить из файла…")) { updater.chooseUpdate(currentlyBusy: busy) }.disabled(busy || updater.isUpdating)
                }.menuStyle(.borderlessButton)
            }
            if !updater.status.isEmpty { Text(updater.status).font(.caption).foregroundStyle(.secondary) }
            if let error = updater.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
        .onChange(of: busy, initial: true) { _, value in updater.setBusy(value) }
    }
}
