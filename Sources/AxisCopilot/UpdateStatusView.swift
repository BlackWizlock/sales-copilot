import SwiftUI

struct UpdateStatusView: View {
    @ObservedObject var updater: AppUpdater
    let busy: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Установить обновление…", systemImage: "arrow.down.app") { updater.chooseUpdate(currentlyBusy: busy) }.disabled(busy)
            if !updater.status.isEmpty { Text(updater.status).font(.caption).foregroundStyle(.secondary) }
            if let error = updater.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
}
