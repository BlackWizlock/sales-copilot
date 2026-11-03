import SwiftUI
import AVFoundation
import ScreenCaptureKit
import CopilotCore

enum CapturePhase { case idle, starting, recording, stopping }

@MainActor final class MeetingModel: ObservableObject {
    @Published var phase: CapturePhase = .idle
    @Published var sessions: [MeetingSession] = []
    @Published var current: MeetingSession? { didSet { coordinateFeatures() } }
    @Published var applications: [SCRunningApplication] = []
    @Published var selectedPID: Int32 = 0
    @Published var title = L10n.string("Новая встреча")
    @Published var error: String?
    @Published var status = L10n.string("Готов к настройке")
    @Published var levels: [AudioSource: Float] = [:]
    @Published var lastSamples: [AudioSource: Double] = [:]
    @Published var clock = Date()
    @Published var processing = false
    @Published var exporting = false
    @Published var refreshing = false
    @Published var modelPath: String = UserDefaults.standard.string(forKey: "modelPath") ?? LocalTranscriber.defaultModel.path
    @Published var executablePath: String = UserDefaults.standard.string(forKey: "executablePath") ?? LocalTranscriber.defaultExecutable.path
    private(set) var store: SessionStore?
    private var startupFailure: String?
    private var capture: AudioCapture?
    private var worker: Task<Void, Never>?
    private var timer: Timer?
    let playback = PlaybackController()
    let updater = AppUpdater()
    @Published var preparingPlayback = false
    @Published var analyzingSpeakers = false
    @Published var speakerStatus = L10n.string("Голоса ещё не разделены")
    private var speakerAttempts = Set<UUID>()
    let intelligence = LocalIntelligence()
    let asrModels = ASRModelManager()
    private(set) var crm: CRMController?

    var updateBusy: Bool { phase != .idle || processing || exporting || preparingPlayback || analyzingSpeakers || intelligence.busyMaterials || intelligence.busySummary || intelligence.busySuggestion || intelligence.busyChat || crm?.busy == true }
    var locked: Bool { intelligence.busyMaterials || phase != .idle || processing || exporting || preparingPlayback || analyzingSpeakers || updater.isInstalling }
    var pending: Int { current?.chunks.filter { $0.state == .pending }.count ?? 0 }
    var failed: Int { current?.chunks.filter { $0.state == .failed }.count ?? 0 }
    var elapsed: String {
        guard let current else { return "00:00" }
        let seconds = Int(max(0, (current.ended ?? clock).timeIntervalSince(current.created)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var transcriber: LocalTranscriber {
        LocalTranscriber.selected(executable: URL(fileURLWithPath: executablePath), fallbackModel: URL(fileURLWithPath: modelPath))
    }

    init() {
        do {
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AxisSalesCopilot/Meetings")
            store = try SessionStore(root: root)
            crm = CRMController(store: store!)
            sessions = try store!.loadAll()
            if let warning = store?.loadWarnings.first { error = warning }
        } catch { self.error = L10n.format("Хранилище недоступно: %@", String(describing: L10n.error(error))) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.clock = Date() }
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(modelPath, forKey: "modelPath")
        UserDefaults.standard.set(executablePath, forKey: "executablePath")
    }

    private func coordinateFeatures() {
        crm?.activate(session: current)
        intelligence.observe(current, directory: current.flatMap { store?.directory($0.id) })
        if let id = current?.id, let context = crm?.context(for: id), intelligence.record.dealText != context.asPlainText {
            intelligence.record.dealText = context.asPlainText
            intelligence.updateContext()
        }
    }

    func refreshApplications() async {
        guard !refreshing, phase == .idle else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let content = try await SCShareableContent.current
            applications = content.applications.filter { !$0.applicationName.isEmpty && $0.processID != ProcessInfo.processInfo.processIdentifier }
                .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
            if selectedPID != 0 && !applications.contains(where: { $0.processID == selectedPID }) { selectedPID = 0 }
            status = L10n.string("Выберите приложение встречи и нажмите «Начать»")
        } catch { self.error = L10n.format("Нет доступа к звуку экрана: %@. Разрешите запись экрана и системного аудио в настройках macOS.", String(describing: L10n.error(error))) }
    }

    func start() async {
        guard !locked, let store else { return }
        playback.stop()
        phase = .starting; startupFailure = nil; error = nil; levels = [:]; lastSamples = [:]
        saveSettings()
        do {
            try transcriber.validate()
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else { throw CopilotError.message(L10n.string("Разрешите доступ к микрофону в настройках конфиденциальности macOS.")) }
            let content = try await SCShareableContent.current
            let application = content.applications.first { $0.processID == selectedPID }
            if selectedPID != 0 && application == nil { throw CopilotError.message(L10n.string("Выбранное приложение закрыто. Обновите список.")) }
            var session = try store.create(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.string("Встреча") : title)
            session.sourceName = application?.applicationName ?? L10n.string("Все приложения")
            crm?.activate(session: session, isNew: true)
            current = session
            try store.save(session)
            let id = session.id
            let capture = AudioCapture()
            capture.onChunk = { [weak self] chunk in
                Task { @MainActor in self?.accept(chunk, sessionID: id) }
            }
            capture.onLevel = { [weak self] source, level, time in
                Task { @MainActor in
                    guard self?.current?.id == id else { return }
                    self?.levels[source] = level; self?.lastSamples[source] = time
                }
            }
            capture.onError = { [weak self] message in
                Task { @MainActor in
                    guard let self, self.current?.id == id else { return }
                    self.error = message; self.current?.issues.append(message); self.persist()
                    if self.phase == .starting { self.startupFailure = message }
                    if self.phase == .recording { await self.stop(interrupted: true) }
                }
            }
            self.capture = capture
            try await capture.start(content: content, application: application, folder: store.directory(id))
            if let startupFailure { throw CopilotError.message(startupFailure) }
            phase = .recording
            status = L10n.string("Запись идёт. Проверяйте оба индикатора звука.")
        } catch {
            if let capture { _ = try? await capture.stop() }
            capture = nil; phase = .idle
            if current?.state == .recording { current?.state = .interrupted; current?.ended = Date(); persist() }
            self.error = L10n.error(error)
            status = L10n.string("Запись не началась")
        }
    }

    func stop(interrupted: Bool = false) async {
        guard phase == .recording else { return }
        phase = .stopping
        var stopFailed = false
        do {
            let chunks = try await capture?.stop() ?? []
            if let id = current?.id { for chunk in chunks { accept(chunk, sessionID: id) } }
        } catch { stopFailed = true; self.error = L10n.error(error); current?.issues.append(L10n.error(error)) }
        if let id = current?.id, let capture {
            for chunk in capture.savedChunks() { accept(chunk, sessionID: id) }
        }
        capture = nil
        current?.ended = Date()
        current?.state = interrupted || stopFailed ? .interrupted : .processing
        phase = .idle
        persist()
        status = L10n.string("Запись завершена. Дораспознаём сохранённое аудио.")
        kickWorker()
        await exportRecording()
        completeIfReady()
    }

    func accept(_ chunk: AudioChunk, sessionID: UUID) {
        guard current?.id == sessionID, current?.chunks.contains(where: { $0.id == chunk.id }) == false else { return }
        current?.chunks.append(chunk)
        persist()
        kickWorker()
    }

    private func kickWorker() {
        guard worker == nil, let id = current?.id, let store else { return }
        processing = true
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil; self.processing = false; self.completeIfReady() }
            while self.current?.id == id,
                  let chunk = self.current?.chunks.first(where: { $0.state == .pending }) {
                do {
                    let lines: [TranscriptLine]
                    if chunk.rms < 0.0005 || chunk.duration < 0.15 { lines = [] }
                    else { lines = try await self.transcriber.transcribe(url: store.fileURL(id, filename: chunk.filename), chunk: chunk) }
                    guard self.current?.id == id else { return }
                    self.current?.transcript.append(contentsOf: lines)
                    self.current?.transcript.sort { $0.start < $1.start }
                    self.setChunk(chunk.id, state: .completed, error: nil)
                } catch {
                    self.setChunk(chunk.id, state: .failed, error: L10n.error(error))
                    self.error = L10n.error(error)
                }
                self.persist()
            }
        }
    }

    private func setChunk(_ id: UUID, state: ChunkState, error: String?) {
        guard let index = current?.chunks.firstIndex(where: { $0.id == id }) else { return }
        current?.chunks[index].state = state; current?.chunks[index].error = error
    }

    private func completeIfReady() {
        guard phase == .idle, !processing, !exporting, current != nil else { return }
        if current?.state == .processing {
            current?.state = failed > 0 ? .interrupted : .completed
            persist()
        }
        if current?.state == .interrupted { status = L10n.string("Встреча прервана. Сохранённые фрагменты доступны."); return }
        status = failed > 0 ? L10n.string("Аудио сохранено. Часть фрагментов требует повторного распознавания.") : L10n.string("Встреча сохранена локально")
        if let current, current.state == .completed, current.speakerTurns == nil, !speakerAttempts.contains(current.id), !analyzingSpeakers { analyzeSpeakers() }
    }

    func retryTranscription() {
        guard !locked, current != nil else { return }
        for i in current!.chunks.indices where current!.chunks[i].state == .failed { current!.chunks[i].state = .pending }
        persist(); kickWorker()
    }

    func select(_ id: UUID) {
        guard !locked else { return }
        playback.stop()
        current = sessions.first { $0.id == id }
        if let current { title = current.title }
        speakerStatus = current?.speakerTurns == nil ? L10n.string("Голоса ещё не разделены") : L10n.string("Голоса разделены локально")
        levels = [:]; lastSamples = [:]; error = nil
    }

    func newMeeting() {
        guard !locked else { return }
        playback.stop(); current = nil; title = L10n.string("Новая встреча"); levels = [:]; lastSamples = [:]; error = nil
        status = L10n.string("Выберите приложение встречи и нажмите «Начать»")
    }

    func deleteMeeting(_ id: UUID) {
        guard !locked, !updateBusy, let store else { return }
        playback.stop()
        do {
            try store.deleteMeeting(id)
            if current?.id == id { newMeeting() }
            sessions.removeAll { $0.id == id }
            speakerAttempts.remove(id)
        } catch { self.error = L10n.string("Не удалось удалить встречу") + ": " + L10n.error(error) }
    }

    func analyzeSpeakers() {
        guard !locked, let current, let store else { return }
        speakerAttempts.insert(current.id)
        analyzingSpeakers = true; speakerStatus = L10n.string("Разделяем голоса на этом Mac")
        Task {
            defer { analyzingSpeakers = false }
            do {
                let turns = try await LocalDiarizer().process(session: current, store: store)
                guard self.current?.id == current.id else { return }
                self.current?.applySpeakerTurns(turns)
                speakerStatus = turns.isEmpty ? L10n.string("Речь для разделения голосов не найдена") : L10n.string("Голоса разделены локально. Проверьте назначения.")
                persist()
            } catch { speakerStatus = L10n.format("Голоса не разделены: %@", String(describing: L10n.error(error))) }
        }
    }

    func renameSpeaker(_ id: String, name: String) {
        guard !analyzingSpeakers, let index = current?.speakers?.firstIndex(where: { $0.id == id }) else { return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        current?.speakers?[index].name = String(value.prefix(120)); persist()
    }

    func assignSpeaker(_ id: String?, to phrase: UUID) {
        guard !analyzingSpeakers else { return }
        current?.setSpeakerOverride(phraseID: phrase, speakerID: id); persist()
    }

    private func persist() {
        guard let current, let store else { return }
        do {
            try store.save(current)
            if let i = sessions.firstIndex(where: { $0.id == current.id }) { sessions[i] = current }
            else { sessions.insert(current, at: 0) }
        } catch { self.error = L10n.format("Не удалось сохранить состояние встречи: %@", String(describing: L10n.error(error))) }
    }

    func revealFolder() {
        guard let store else { return }
        NSWorkspace.shared.open(current.map { store.directory($0.id) } ?? store.root)
    }

    func play(_ line: TranscriptLine? = nil) {
        guard phase == .idle, !preparingPlayback, !exporting, let current, let store else { return }
        let original: URL
        do { original = try store.fileURL(current.id, filename: "meeting.m4a") }
        catch { self.error = L10n.format("Не удалось воспроизвести: %@. Исходные фрагменты сохранены.", L10n.error(error)); return }
        let archive = playback.preferEchoReduced ? (echoReducedURL ?? original) : original
        if playback.isLoaded(from: archive) {
            if let line { playback.seek(to: line.start); playback.play() }
            else { playback.toggle() }
            return
        }
        preparingPlayback = true
        Task {
            defer { preparingPlayback = false }
            do {
                let archive = playback.preferEchoReduced ? (echoReducedURL ?? original) : original
                if !FileManager.default.fileExists(atPath: archive.path) {
                    guard !current.chunks.isEmpty else { throw CopilotError.message(L10n.string("У этой встречи нет аудиозаписи")) }
                    try await RecordingExport.export(session: current, store: store)
                }
                guard self.current?.id == current.id, phase == .idle else { return }
                try playback.load(url: archive)
                if let line { playback.seek(to: line.start) }
                playback.play()
            } catch { self.error = L10n.format("Не удалось воспроизвести: %@. Исходные фрагменты сохранены.", String(describing: L10n.error(error))) }
        }
    }

    private var echoReducedURL: URL? {
        guard let current, let store else { return nil }
        return PlaybackController.echoReducedURL(store: store, meetingID: current.id)
    }
    var hasEchoReduced: Bool { echoReducedURL != nil }

    var recordingURL: URL? {
        guard let current, let store, let url = try? store.fileURL(current.id, filename: "meeting.m4a"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func prepareRecordingForCRM() async throws -> URL {
        guard phase == .idle, !processing, !preparingPlayback, !exporting, let current, let store else {
            throw CopilotError.message(L10n.string("Дождитесь завершения записи и транскрипции"))
        }
        if let recordingURL { return recordingURL }
        guard !current.chunks.isEmpty else { throw CopilotError.message(L10n.string("У этой встречи нет аудиозаписи")) }
        exporting = true
        defer { exporting = false }
        try await RecordingExport.export(session: current, store: store)
        guard self.current?.id == current.id, let recordingURL else {
            throw CopilotError.message(L10n.string("Встреча изменилась. Откройте отправку заново."))
        }
        return recordingURL
    }

    func exportRecording() async {
        do { _ = try await prepareRecordingForCRM() }
        catch { self.error = L10n.format("Исходные WAV сохранены; сборка M4A не удалась: %@", String(describing: L10n.error(error))) }
    }
}
