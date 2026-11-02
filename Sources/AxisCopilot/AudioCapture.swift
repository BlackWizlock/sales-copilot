import AVFoundation
import ScreenCaptureKit
import CopilotCore

/// All sample buffers and file writes are confined to audioQueue.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onChunk: ((AudioChunk) -> Void)?
    var onLevel: ((AudioSource, Float, Double) -> Void)?
    var onError: ((String) -> Void)?
    private let audioQueue = DispatchQueue(label: "ru.axisconsult.copilot.audio", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AudioChunkWriter?
    private var origin: Double?
    private var lastMeter: [AudioSource: Double] = [:]
    private var active = false
    private var failed = false

    func start(content: SCShareableContent, application: SCRunningApplication?, folder: URL) async throws {
        guard let display = content.displays.first else { throw CopilotError.message("Нет доступного экрана") }
        let filter: SCContentFilter
        if let application {
            filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
        } else {
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        }
        let configuration = SCStreamConfiguration()
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000; configuration.channelCount = 2
        configuration.captureMicrophone = true
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        // Discard screen frames; only audio is persisted.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: audioQueue)
        audioQueue.sync {
            writer = AudioChunkWriter(folder: folder)
            writer?.onChunk = { [weak self] in self?.onChunk?($0) }
            origin = nil; lastMeter = [:]; active = true; failed = false
        }
        self.stream = stream
        do { try await stream.startCapture() }
        catch { audioQueue.sync { active = false }; self.stream = nil; throw error }
    }

    func stop() async throws -> [AudioChunk] {
        var stopError: Error?
        if let stream { do { try await stream.stopCapture() } catch { stopError = error } }
        self.stream = nil
        let result = try audioQueue.sync { () throws -> [AudioChunk] in
            active = false
            try writer?.flush()
            return writer?.written ?? []
        }
        if let stopError { throw stopError }
        return result
    }

    /// Drain successful writes even when stop throws for the other source.
    func savedChunks() -> [AudioChunk] { audioQueue.sync { writer?.written ?? [] } }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        audioQueue.async { [self] in
            active = false
            do { try writer?.flush() } catch { failed = true }
            onError?("Захват звука остановлен: \(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard active, !failed, sampleBuffer.isValid, type == .audio || type == .microphone else { return }
        let source: AudioSource = type == .microphone ? .microphone : .meeting
        do {
            let samples = try Self.resample(sampleBuffer)
            guard !samples.isEmpty else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            if origin == nil { origin = pts }
            let time = max(0, pts - (origin ?? pts))
            let now = ProcessInfo.processInfo.systemUptime
            let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
            if now - (lastMeter[source] ?? 0) > 0.12 {
                lastMeter[source] = now
                onLevel?(source, rms, now)
            }
            try writer?.append(samples, source: source, at: time)
        } catch {
            failed = true
            onError?("Ошибка записи \(source.title): \(error.localizedDescription). Завершите встречу; уже сохранённые сегменты доступны.")
        }
    }

    private static func resample(_ sample: CMSampleBuffer) throws -> [Float] {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw CopilotError.message("Неподдерживаемый формат звука")
        }
        input.frameLength = input.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(input.frameLength), into: input.mutableAudioBufferList)
        guard status == noErr else { throw CopilotError.message("Ошибка PCM: \(status)") }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        guard result != .error, let pointer = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: Int(output.frameLength)))
    }
}
