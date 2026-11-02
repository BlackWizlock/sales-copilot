import SwiftUI
import AppKit

@MainActor final class CopilotSettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var draft: SettingsDraft?
    static let shared = CopilotSettingsWindow()
    func show(model: MeetingModel, page: Int? = nil) {
        if let window {
            if let page { draft?.page = page }
            window.deminiaturize(nil); window.makeKeyAndOrderFront(nil); return
        }
        let draft = SettingsDraft(model: model)
        draft.page = page ?? 0
        self.draft = draft
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.string("Настройки Axis Copilot")
        window.minSize = NSSize(width: 780, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: CopilotSettingsView(model: model, draft: draft, close: { [weak window] in window?.close() }))
        self.window = window
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { window = nil; draft = nil }
}

@MainActor final class SettingsDraft: ObservableObject {
    @Published var page = 0
    @Published var executable: String
    @Published var modelPath: String
    init(model: MeetingModel) { executable = model.executablePath; modelPath = model.modelPath }
}

struct CopilotSettingsView: View {
    @ObservedObject var model: MeetingModel
    var close: () -> Void
    @StateObject private var draft: SettingsDraft
    @ObservedObject private var language = UILanguageSettings.shared
    init(model: MeetingModel, draft: SettingsDraft, close: @escaping () -> Void) {
        self.model = model; self.close = close
        _draft = StateObject(wrappedValue: draft)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    navigation(L10n.string("Общие"), icon: "gearshape", page: 0)
                    navigation(L10n.string("Распознавание"), icon: "waveform", page: 1)
                    navigation(L10n.string("Локальный ИИ"), icon: "desktopcomputer", page: 2)
                    navigation(L10n.string("Битрикс24"), icon: "link", page: 3)
                    navigation("OpenRouter", icon: "cloud", page: 4)
                    navigation(L10n.string("Доступ агентам"), icon: "terminal", page: 5)
                    Spacer()
                }.padding(16).frame(width: 190).background(Color(nsColor: .windowBackgroundColor))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch draft.page {
                        case 0: LocaleSettingsView()
                        case 1:
                            ASRModelsView(manager: model.asrModels, busy: model.updateBusy)
                            DisclosureGroup(L10n.string("Дополнительно")) {
                                VStack(alignment: .leading, spacing: 10) {
                                    TextField(L10n.string("Путь к whisper-cli"), text: $draft.executable)
                                    TextField(L10n.string("Путь к модели .bin"), text: $draft.modelPath)
                                    HStack {
                                        Button(L10n.string("Отмена")) { draft.executable = model.executablePath; draft.modelPath = model.modelPath }
                                        Button(L10n.string("Сохранить пути")) { guard !model.updateBusy else { return }; model.executablePath = draft.executable; model.modelPath = draft.modelPath; model.saveSettings() }.disabled(model.updateBusy)
                                    }
                                }.padding(.top, 8)
                            }
                        case 2: LocalIntelligenceSettingsView()
                        case 3: if let crm = model.crm { BitrixConnectionSettingsView(controller: crm) }
                        case 4: OpenRouterSettingsView()
                        default: if let store = model.store { MCPAccessPanel(session: model.current, store: store) }
                        }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack {
                Text(L10n.string("Язык и выбор модели применяются сразу. Ключи сохраняются отдельной кнопкой."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("Закрыть"), action: close).keyboardShortcut(.cancelAction)
            }.padding(16)
        }.textFieldStyle(.roundedBorder).tint(AxisBrand.teal).environment(\.locale, language.locale)
    }
    private func navigation(_ title: String, icon: String, page: Int) -> some View {
        Button { draft.page = page } label: {
            Label(LocalizedStringKey(title), systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(9)
                .background(draft.page == page ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
    }
}
