import SwiftUI
import AVFoundation
import ScreenCaptureKit
import CopilotCore

enum CapturePhase { case idle, starting, recording, stopping }

@MainActor final class MeetingModel: ObservableObject {
    @Published var showSettings = false
    @Published var phase: CapturePhase = .idle
    @Published var sessions: [MeetingSession] = []
    @Published var current: MeetingSession?
    @Published var applications: [SCRunningApplication] = []
    @Published var selectedPID: Int32 = 0
    @Published var title = "Новая встреча"
    @Published var error: String?
    @Published var status = "Готов к настройке"
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
    private var player: AVAudioPlayer?

    var locked: Bool { phase != .idle || processing || exporting }
    var pending: Int { current?.chunks.filter { $0.state == .pending }.count ?? 0 }
    var failed: Int { current?.chunks.filter { $0.state == .failed }.count ?? 0 }
    var elapsed: String {
        guard let current else { return "00:00" }
        let seconds = Int(max(0, (current.ended ?? clock).timeIntervalSince(current.created)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var transcriber: LocalTranscriber {
        LocalTranscriber(executable: URL(fileURLWithPath: executablePath), model: URL(fileURLWithPath: modelPath))
    }

    init() {
        do {
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AxisSalesCopilot/Meetings")
            store = try SessionStore(root: root)
            sessions = try store!.loadAll()
            if let warning = store?.loadWarnings.first { error = warning }
        } catch { self.error = "Хранилище недоступно: \(error.localizedDescription)" }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.clock = Date() }
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(modelPath, forKey: "modelPath")
        UserDefaults.standard.set(executablePath, forKey: "executablePath")
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
            status = "Выберите приложение встречи и нажмите «Начать»"
        } catch { self.error = "Нет доступа к звуку экрана: \(error.localizedDescription). Разрешите запись экрана и системного аудио в настройках macOS." }
    }

    func start() async {
        guard !locked, let store else { return }
        phase = .starting; startupFailure = nil; error = nil; levels = [:]; lastSamples = [:]
        saveSettings()
        do {
            try transcriber.validate()
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else { throw CopilotError.message("Разрешите доступ к микрофону в настройках конфиденциальности macOS.") }
            let content = try await SCShareableContent.current
            let application = content.applications.first { $0.processID == selectedPID }
            if selectedPID != 0 && application == nil { throw CopilotError.message("Выбранное приложение закрыто. Обновите список.") }
            var session = try store.create(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Встреча" : title)
            session.sourceName = application?.applicationName ?? "Все приложения"
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
            status = "Запись идёт. Проверяйте оба индикатора звука."
        } catch {
            if let capture { _ = try? await capture.stop() }
            capture = nil; phase = .idle
            if current?.state == .recording { current?.state = .interrupted; current?.ended = Date(); persist() }
            self.error = error.localizedDescription
            status = "Запись не началась"
        }
    }

    func stop(interrupted: Bool = false) async {
        guard phase == .recording else { return }
        phase = .stopping
        var stopFailed = false
        do {
            let chunks = try await capture?.stop() ?? []
            if let id = current?.id { for chunk in chunks { accept(chunk, sessionID: id) } }
        } catch { stopFailed = true; self.error = error.localizedDescription; current?.issues.append(error.localizedDescription) }
        if let id = current?.id, let capture {
            for chunk in capture.savedChunks() { accept(chunk, sessionID: id) }
        }
        capture = nil
        current?.ended = Date()
        current?.state = interrupted || stopFailed ? .interrupted : .processing
        phase = .idle
        persist()
        status = "Запись завершена. Дораспознаём сохранённое аудио."
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
                    self.setChunk(chunk.id, state: .failed, error: error.localizedDescription)
                    self.error = error.localizedDescription
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
        if current?.state == .interrupted { status = "Встреча прервана. Сохранённые фрагменты доступны."; return }
        status = failed > 0 ? "Аудио сохранено. Часть фрагментов требует повторного распознавания." : "Встреча сохранена локально"
    }

    func retryTranscription() {
        guard !locked, current != nil else { return }
        for i in current!.chunks.indices where current!.chunks[i].state == .failed { current!.chunks[i].state = .pending }
        persist(); kickWorker()
    }

    func select(_ id: UUID) {
        guard !locked else { return }
        player?.stop()
        current = sessions.first { $0.id == id }
        levels = [:]; lastSamples = [:]; error = nil
    }

    private func persist() {
        guard let current, let store else { return }
        do {
            try store.save(current)
            if let i = sessions.firstIndex(where: { $0.id == current.id }) { sessions[i] = current }
            else { sessions.insert(current, at: 0) }
        } catch { self.error = "Не удалось сохранить состояние встречи: \(error.localizedDescription)" }
    }

    func revealFolder() {
        guard let store else { return }
        NSWorkspace.shared.open(current.map { store.directory($0.id) } ?? store.root)
    }

    func play(_ line: TranscriptLine? = nil) {
        guard let current, let store else { return }
        do {
            let archive = try store.fileURL(current.id, filename: "meeting.m4a")
            if FileManager.default.fileExists(atPath: archive.path) {
                player = try AVAudioPlayer(contentsOf: archive)
                player?.currentTime = line?.start ?? 0
            } else if let chunk = current.chunks.first(where: { line == nil || $0.id == line?.chunkID }) {
                player = try AVAudioPlayer(contentsOf: store.fileURL(current.id, filename: chunk.filename))
                player?.currentTime = max(0, (line?.start ?? chunk.start) - chunk.start)
            }
            player?.play()
        } catch { self.error = "Не удалось воспроизвести: \(error.localizedDescription)" }
    }

    func exportRecording() async {
        guard let current, let store, !current.chunks.isEmpty, !exporting else { return }
        exporting = true
        defer { exporting = false }
        do { try await RecordingExport.export(session: current, store: store) }
        catch { self.error = "Исходные WAV сохранены; сборка M4A не удалась: \(error.localizedDescription)" }
    }
}
