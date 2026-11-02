import Foundation
import CopilotCore
import AVFoundation

@MainActor enum ASRVerification {
    static func run() async throws {
        let verified = try await ASRModelManager.verifiedSharedParakeet()
        print("PASS: shared Parakeet v3, \(verified.count) files, \(verified.bytes) bytes match upstream revision \(verified.revision) and integrity metadata; cache unchanged")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axis-asr-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let aiff = root.appendingPathComponent("synthetic.aiff"), wav = root.appendingPathComponent("synthetic.wav")
        try UpdateValidation.command("/usr/bin/say", ["-v", "Milena", "-r", "175", "-o", aiff.path, "Добрый день. Мы обсуждаем коммерческое предложение. Стоимость проекта составляет сто тысяч рублей. Срок выполнения работы четыре недели."])
        try UpdateValidation.command("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
        func canonicalSamples() throws -> [Float] {
            let file = try AVAudioFile(forReading: wav)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw CopilotError.message("Не удалось создать синтетический аудиобуфер.") }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { throw CopilotError.message("Нужен синтетический float mono буфер.") }
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        try WaveFile.encode(canonicalSamples()).write(to: wav, options: .atomic)
        let wave = try WaveFile.decode(Data(contentsOf: wav))
        let transcriber = LocalTranscriber(executable: LocalTranscriber.defaultExecutable, model: ASRModelManager.sharedParakeet, engine: .parakeet)
        let chunk = AudioChunk(source: .meeting, start: 0, duration: Double(wave.samples.count) / 16000, filename: "synthetic.wav")
        let started = Date()
        let lines = try await transcriber.transcribe(url: wav, chunk: chunk)
        let seconds = Date().timeIntervalSince(started)
        let text = lines.map(\.text).joined(separator: " ")
        guard text.lowercased().contains("проект"), text.lowercased().contains("недел") else { throw CopilotError.message("Parakeet не распознал ключевые слова синтетической русской фразы: \(text)") }
        print("PASS: Parakeet Russian synthetic text: \(text)")
        print("MEASURED: \(String(format: "%.2f", seconds)) seconds including first model load for \(String(format: "%.2f", chunk.duration)) seconds audio")
        let warmStarted = Date()
        _ = try await transcriber.transcribe(url: wav, chunk: chunk)
        print("MEASURED: warm model \(String(format: "%.2f", Date().timeIntervalSince(warmStarted))) seconds for \(String(format: "%.2f", chunk.duration)) seconds audio")
        let tail = root.appendingPathComponent("tail.wav")
        try WaveFile.encode(Array(wave.samples.prefix(8000))).write(to: tail)
        let tailChunk = AudioChunk(source: .microphone, start: 5, duration: 0.5, filename: "tail.wav")
        let tailLines = try await transcriber.transcribe(url: tail, chunk: tailChunk)
        guard tailLines.allSatisfy({ $0.start >= 5 && $0.end <= 5.5 }) else { throw CopilotError.message("Неверная шкала времени короткого фрагмента.") }
        print("PASS: subsecond tail padding keeps the original chunk timeline")
    }
}
