import SwiftUI
import AppKit
import CopilotCore

@MainActor private final class MCPAccessState: ObservableObject {
    @Published var enabled = false
    @Published var allowed = false
    @Published var error: String?
    @Published var copied = ""
    func load(session: MeetingSession?, store: SessionStore) {
        do {
            let p = try MCPAccessStore(root: store.root).load()
            enabled = p.enabled; allowed = session.map { p.allowedMeetings.contains($0.id) } ?? false; error = nil
        } catch { enabled = false; allowed = false; self.error = L10n.string("Не удалось прочитать разрешения доступа") }
    }
    func setEnabled(_ value: Bool, session: MeetingSession?, store: SessionStore) {
        do { try MCPAccessStore(root: store.root).setEnabled(value); load(session: session, store: store) }
        catch { self.error = L10n.string("Не удалось сохранить разрешение доступа") }
    }
    func setAllowed(_ value: Bool, session: MeetingSession?, store: SessionStore) {
        guard let session else { return }
        do { try MCPAccessStore(root: store.root).setAllowed(session.id, allowed: value); load(session: session, store: store) }
        catch { self.error = L10n.string("Не удалось сохранить разрешение встречи") }
    }
}
struct MCPAccessPanel: View {
    var session: MeetingSession?
    let store: SessionStore
    @StateObject private var ui = MCPAccessState()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("Доступ внешних агентов")).font(.title2.bold())
            Text(L10n.string("MCP даёт агенту выбранные тексты встреч, итоги и локальный снимок сделки. Если агент использует облачную модель, прочитанный текст покидает Mac. Включайте доступ только к разрешённым материалам."))
            Toggle(L10n.string("Разрешить чтение через MCP"), isOn: Binding(get: { ui.enabled }, set: { ui.setEnabled($0, session: session, store: store) }))
            if let session {
                Toggle(L10n.format("Разрешить встречу «%@»", String(describing: session.title)), isOn: Binding(get: { ui.allowed }, set: { ui.setAllowed($0, session: session, store: store) }))
                    .disabled(!ui.enabled)
            } else { Text(L10n.string("Выберите встречу, затем разрешите доступ именно к ней.")).foregroundStyle(.secondary) }
            Text(L10n.string("Новые встречи закрыты по умолчанию. Выключение действует на следующий запрос уже подключённого агента. Запись, CRM и аудиофайлы через MCP недоступны.")).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(L10n.string("Подключить клиент MCP")) {
                Text(L10n.string("Запустите исполняемый файл установленного приложения с аргументом --mcp. Это локальный транспорт stdin/stdout, без порта и публичного сервера. Путь можно скопировать ниже.")).font(.callout)
                Text(Bundle.main.executableURL?.path ?? "AxisCopilot.app/Contents/MacOS/AxisCopilot").font(.caption.monospaced()).textSelection(.enabled)
                Text(L10n.string("Аргументы: [\"--mcp\"]")).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button(L10n.string("Скопировать JSON для агента")) { copyConfiguration(codex: false) }
                    Button(L10n.string("Скопировать для Codex")) { copyConfiguration(codex: true) }
                }
                if !ui.copied.isEmpty { Text(ui.copied).font(.caption).foregroundStyle(.secondary) }
            }
            if let error = ui.error { Text(error).foregroundStyle(.red) }
            Button(L10n.string("Обновить разрешения")) { ui.load(session: session, store: store) }
        }.padding(20)
        .task { ui.load(session: session, store: store) }
        .onChange(of: session?.id) { _, _ in ui.load(session: session, store: store) }
    }
    private func copyConfiguration(codex: Bool) {
        guard let path = Bundle.main.executableURL?.path,
              let encoded = try? JSONSerialization.data(withJSONObject: path, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let quoted = String(data: encoded, encoding: .utf8) else { return }
        let value: String
        if codex { value = "[mcp_servers.axis-copilot]\ncommand = " + quoted + "\nargs = [\"--mcp\"]\n" }
        else {
            let config: [String: Any] = ["mcpServers": ["axis-copilot": ["command": path, "args": ["--mcp"]]]]
            guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) else { return }
            value = text
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        ui.copied = codex ? L10n.string("Скопирована секция config.toml для Codex. Доступ к встречам включается отдельно.") : L10n.string("Скопирована конфигурация MCP. Доступ к встречам включается отдельно.")
    }
}
