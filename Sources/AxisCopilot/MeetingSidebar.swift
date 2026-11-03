import SwiftUI
import CopilotCore

@MainActor private final class SidebarState: ObservableObject {
    @Published var query = ""
    @Published var library = MeetingLibrary()
    @Published var ready = false
    @Published var folderID: UUID?
    @Published var unfiled = false
    @Published var folderName = ""
    @Published var editingFolder: UUID?
    @Published var showFolderEditor = false
    @Published var bindings: [UUID: DealContext] = [:]
}

struct MeetingSidebar: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var crm: CRMController
    @Binding var showCalendar: Bool
    let delete: (MeetingSession) -> Void
    @StateObject private var state = SidebarState()
    @AppStorage("meetingLibrarySort") private var sortValue = "newest"
    @AppStorage("meetingLibraryGroupDates") private var groupDates = true
    private var sort: MeetingLibrary.Sort { .init(rawValue: sortValue) ?? .newest }
    private var groupByDay: Bool { groupDates && sort != .title }
    private var sessions: [MeetingSession] { state.library.filtered(model.sessions, folder: state.folderID, unfiled: state.unfiled, query: state.query, sort: sort) }
    private var folderTitle: String {
        if state.unfiled { return L10n.string("Без папки") }
        return state.library.folders.first { $0.id == state.folderID }?.name ?? L10n.string("Все встречи")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                navigation(L10n.string("Встречи"), icon: "text.bubble", calendar: false)
                navigation(L10n.string("Календарь"), icon: "calendar", calendar: true)
                Button { showCalendar = false; model.newMeeting() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help(L10n.string("Новая встреча")).disabled(model.locked)
            }
            TextField(L10n.string("Найти встречу"), text: $state.query).textFieldStyle(.roundedBorder)
            HStack {
                Menu {
                    Button(L10n.string("Все встречи")) { state.folderID = nil; state.unfiled = false }
                    Button(L10n.string("Без папки")) { state.folderID = nil; state.unfiled = true }
                    Divider()
                    ForEach(state.library.folders) { folder in
                        Button(folder.name) { state.folderID = folder.id; state.unfiled = false }
                    }
                    Divider()
                    Button(L10n.string("Создать папку")) { state.editingFolder = nil; state.folderName = ""; state.showFolderEditor = true }
                    if let folderID = state.folderID {
                        Button(L10n.string("Переименовать папку")) {
                            state.editingFolder = state.folderID; state.folderName = folderTitle; state.showFolderEditor = true
                        }
                        Button(L10n.string("Удалить папку"), role: .destructive) {
                            change { $0.removeFolder(folderID) }
                            state.folderID = nil
                        }
                    }
                } label: { Label(folderTitle, systemImage: "folder").lineLimit(1) }
                .menuStyle(.borderlessButton).disabled(!state.ready)
                Spacer(minLength: 0)
                Menu {
                    Picker(L10n.string("Сортировка"), selection: $sortValue) {
                        Text(L10n.string("Сначала новые")).tag("newest")
                        Text(L10n.string("Сначала старые")).tag("oldest")
                        Text(L10n.string("По названию")).tag("title")
                    }
                    Toggle(L10n.string("Группировать по дням"), isOn: $groupDates).disabled(sort == .title)
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .menuStyle(.borderlessButton).fixedSize().help(L10n.string("Сортировка"))
            }.font(.caption)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if sessions.isEmpty {
                        Text(model.sessions.isEmpty ? L10n.string("Здесь будут ваши встречи") : L10n.string("Совпадений нет"))
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    if groupByDay {
                        ForEach(days, id: \.self) { day in
                            Text(day, format: .dateTime.day().month(.wide).year())
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, 10).padding(.horizontal, 8)
                            ForEach(sessions.filter { Calendar.current.isDate($0.created, inSameDayAs: day) }) { row($0) }
                        }
                    } else {
                        ForEach(sessions) { row($0) }
                    }
                }
            }
            Divider()
            HStack {
                Button { CopilotSettingsWindow.shared.show(model: model) } label: { Label(L10n.string("Настройки"), systemImage: "gearshape") }
                Spacer()
                Menu {
                    Button(L10n.string("Открыть папку записей")) { model.revealFolder() }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }.buttonStyle(.borderless).font(.callout)
            UpdateStatusView(updater: model.updater, busy: model.updateBusy).font(.caption)
        }
        .padding(12).frame(minWidth: 220, idealWidth: 250, maxWidth: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { load(); refreshBindings() }
        .onChange(of: model.sessions.map(\.id)) { refreshBindings() }
        .onReceive(crm.$context) { _ in
            // Published values arrive before the property is updated.
            Task { @MainActor in refreshBindings() }
        }
        .alert(L10n.string("Имя папки"), isPresented: $state.showFolderEditor) {
            TextField(L10n.string("Имя папки"), text: $state.folderName)
            Button(L10n.string("Сохранить")) {
                change { value in
                    if let editingFolder = state.editingFolder { try value.renameFolder(editingFolder, to: state.folderName) }
                    else { _ = try value.createFolder(state.folderName) }
                }
            }
            Button(L10n.string("Отмена"), role: .cancel) {}
        } message: { Text(L10n.string("Удаление папки сохраняет все встречи.")) }
    }
    private var days: [Date] {
        let unique = Set(sessions.map { Calendar.current.startOfDay(for: $0.created) })
        return unique.sorted { sort == .oldest ? $0 < $1 : $0 > $1 }
    }
    private func navigation(_ title: String, icon: String, calendar: Bool) -> some View {
        Button { showCalendar = calendar } label: {
            Label(title, systemImage: icon).font(.callout)
                .padding(.horizontal, 7).padding(.vertical, 7)
                .background(showCalendar == calendar ? AxisBrand.teal.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
    private func row(_ session: MeetingSession) -> some View {
        MeetingSidebarRow(model: model, state: state, showCalendar: $showCalendar,
                          session: session, groupByDay: groupByDay)
            .contextMenu {
                if let deal = state.bindings[session.id] { Link(L10n.string("Открыть сделку"), destination: deal.url) }
                Menu(L10n.string("Переместить в папку")) {
                    Button(L10n.string("Без папки")) { change { try $0.move(session.id, to: nil) } }
                    ForEach(state.library.folders) { folder in
                        Button(folder.name) { change { try $0.move(session.id, to: folder.id) } }
                    }
                }.disabled(!state.ready)
                Divider()
                Button(L10n.string("Удалить встречу"), role: .destructive) { delete(session) }.disabled(model.locked || model.updateBusy)
            }
    }
    private func refreshBindings() {
        state.bindings = Dictionary(uniqueKeysWithValues: model.sessions.compactMap { session in
            crm.context(for: session.id).map { (session.id, $0) }
        })
    }
    private var metadataURL: URL? { model.store?.root.appendingPathComponent("library.json") }
    private func checkedURL() throws -> URL {
        guard let url = metadataURL else { throw CopilotError.message(L10n.string("Хранилище недоступно")) }
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]), values.isSymbolicLink == true || values.isRegularFile == false {
            throw CopilotError.message(L10n.string("Не удалось прочитать папки встреч. Исходные записи сохранены."))
        }
        return url
    }
    private func load() {
        do {
            let url = try checkedURL()
            if FileManager.default.fileExists(atPath: url.path) { state.library = try JSONDecoder().decode(MeetingLibrary.self, from: Data(contentsOf: url)) }
            state.ready = true
        } catch { model.error = L10n.string("Не удалось прочитать папки встреч. Исходные записи сохранены.") }
    }
    private func change(_ mutation: (inout MeetingLibrary) throws -> Void) {
        guard state.ready else { return }
        do {
            var next = state.library; try mutation(&next)
            let url = try checkedURL()
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            state.library = next
        } catch is MeetingLibrary.ValidationError {
            model.error = L10n.string("Введите уникальное имя папки от 1 до 80 символов.")
        } catch { model.error = L10n.string("Не удалось сохранить папки встреч. Исходные записи сохранены.") }
    }
}

/// Observe selection and deal metadata at the row boundary, independently of
/// ForEach retaining sessions with unchanged identities.
@MainActor private struct MeetingSidebarRow: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var state: SidebarState
    @Binding var showCalendar: Bool
    let session: MeetingSession
    let groupByDay: Bool

    var body: some View {
        Button { showCalendar = false; model.select(session.id) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    if session.state == .recording { Circle().fill(.red).frame(width: 6, height: 6) }
                    if session.state == .interrupted { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help(L10n.string("Прервана · аудио сохранено")) }
                }
                if groupByDay {
                    Text(session.created, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(session.created, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                }
                if let deal = state.bindings[session.id] {
                    Label(deal.title, systemImage: "link").font(.caption).foregroundStyle(AxisBrand.teal).lineLimit(1)
                        .help(deal.title + " · " + deal.portal)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 7)
                .background(!showCalendar && model.current?.id == session.id ? AxisBrand.teal.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.locked)
    }
}
