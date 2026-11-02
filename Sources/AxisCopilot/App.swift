import SwiftUI
import AVFoundation
import CopilotCore

@MainActor final class AppLifecycle: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: MeetingModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.locked else { return .terminateNow }
        showCloseAlert(model)
        return .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, model.locked else { return true }
        showCloseAlert(model)
        return false
    }
    private func showCloseAlert(_ model: MeetingModel) {
        let alert = NSAlert()
        if model.phase == .recording {
            alert.messageText = "Сейчас идёт запись встречи"
            alert.informativeText = "Можно продолжить запись или завершить её. Окно останется открытым до сохранения аудио и текста."
            alert.addButton(withTitle: "Продолжить запись")
            alert.addButton(withTitle: "Завершить запись")
            if alert.runModal() == .alertSecondButtonReturn { Task { await model.stop() } }
        } else {
            alert.messageText = "Подождите завершения операции"
            alert.informativeText = "Идёт запуск, сохранение аудио или локальное распознавание. Приложение можно закрыть после завершения."
            alert.addButton(withTitle: "Продолжить обработку")
            alert.runModal()
        }
    }
}

struct WindowDelegateInstaller: NSViewRepresentable {
    let delegate: AppLifecycle
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.delegate = delegate }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct AxisCopilotApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var model = MeetingModel()
    var body: some Scene {
        WindowGroup("Axis Суфлёр") {
            MeetingView(model: model)
                .background(WindowDelegateInstaller(delegate: lifecycle).frame(width: 0, height: 0))
                .onAppear {
                    lifecycle.model = model
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }.defaultSize(width: 1100, height: 760)
    }
}

@main enum EntryPoint {
    @MainActor static func main() async {
        let arguments = CommandLine.arguments
        if arguments.contains("--diagnostics") {
            do {
                try LocalTranscriber(executable: LocalTranscriber.defaultExecutable, model: LocalTranscriber.defaultModel).validate()
                print("PASS: local whisper-cli and multilingual model available; no capture started")
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if let index = arguments.firstIndex(of: "--verify-fixture"), arguments.count > index + 1 {
            do { try await verifyFixture(URL(fileURLWithPath: arguments[index + 1])) }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        AxisCopilotApp.main()
    }

    private static func verifyFixture(_ url: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axis-copilot-check-\(UUID().uuidString)")
        let store = try SessionStore(root: root)
        var session = try store.create(title: "Synthetic Russian verification")
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CopilotError.message("Fixture must be 16kHz mono WAV")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw CopilotError.message("Fixture PCM missing") }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let transcriber = LocalTranscriber(executable: LocalTranscriber.defaultExecutable, model: LocalTranscriber.defaultModel)
        let started = Date()
        for (source, offset) in [(AudioSource.microphone, 0.0), (.meeting, Double(samples.count) / 16000 + 0.5)] {
            var chunk = AudioChunk(source: source, start: offset, duration: Double(samples.count) / 16000, filename: "\(source.rawValue)-fixture.wav")
            let chunkURL = try store.fileURL(session.id, filename: chunk.filename)
            try WaveFile.encode(samples).write(to: chunkURL)
            let lines = try await transcriber.transcribe(url: chunkURL, chunk: chunk)
            guard !lines.isEmpty, lines.contains(where: { $0.text.contains("100") || $0.text.contains("сто") }) else {
                throw CopilotError.message("Russian fixture transcription did not contain expected price")
            }
            session.transcript.append(contentsOf: lines)
            chunk.state = .completed; session.chunks.append(chunk)
        }
        session.ended = Date(); session.state = .completed
        try store.save(session)
        try await RecordingExport.export(session: session, store: store)
        let archive = try store.fileURL(session.id, filename: "meeting.m4a")
        let asset = AVURLAsset(url: archive)
        let duration = try await asset.load(.duration).seconds
        guard duration >= Double(samples.count) / 16000 * 2 else { throw CopilotError.message("Archive timeline lost a source") }
        let reloaded = try store.loadAll()
        guard reloaded.count == 1, reloaded[0].transcript.count == session.transcript.count else { throw CopilotError.message("Manifest roundtrip failed") }
        print("PASS: two-source Russian transcription, absolute timestamps, manifest reload and M4A export")
        print("Transcription+export seconds: \(String(format: "%.2f", Date().timeIntervalSince(started)))")
        print("Archive seconds: \(String(format: "%.2f", duration))")
        print("Synthetic test folder: \(store.directory(session.id).path)")
    }
}
