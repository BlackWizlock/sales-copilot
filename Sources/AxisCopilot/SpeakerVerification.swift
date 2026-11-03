import Foundation
import AVFoundation
import CopilotCore
import FluidAudio

/// Generates only synthetic speech. Never reads the owner's meetings.
@MainActor enum SpeakerVerification {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axis-speakers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = try store.create(title: "Synthetic three voices")
        let phrases = [
            ("Daniel", "We are discussing a commercial proposal. The project will take four weeks. The team needs a clear schedule and a budget."),
            ("Samantha", "Please explain the delivery plan. We need a clear schedule, a detailed budget, and an agreement about our next meeting."),
            ("Milena", "Добрый день. Мы обсуждаем коммерческое предложение. Стоимость проекта составляет сто тысяч рублей. Срок выполнения работы четыре недели.")
        ]
        var voices: [[Float]] = []
        for (index, phrase) in phrases.enumerated() {
            let aiff = root.appendingPathComponent("voice-\(index).aiff")
            try command("/usr/bin/say", ["-v", phrase.0, "-r", "175", "-o", aiff.path, phrase.1])
            let wav = root.appendingPathComponent("voice-\(index).wav")
            try command("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
            let file = try AVAudioFile(forReading: wav)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { throw CopilotError.message("Synthetic audio not float") }
            voices.append(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
        }
        let diagnosticsModels = try await DiarizerModels.load(
            localSegmentationModel: LocalDiarizer.modelsDirectory.appendingPathComponent("pyannote_segmentation.mlmodelc"),
            localEmbeddingModel: LocalDiarizer.modelsDirectory.appendingPathComponent("wespeaker_v2.mlmodelc"))
        let diagnosticManager = DiarizerManager()
        diagnosticManager.initialize(models: diagnosticsModels)
        let embeddings = try voices.map { try diagnosticManager.extractSpeakerEmbedding(from: $0) }
        for a in 0..<3 {
            for b in (a + 1)..<3 {
                print("EMBEDDING distance \(phrases[a].0)/\(phrases[b].0): \(SpeakerUtilities.cosineDistance(embeddings[a], embeddings[b]))")
            }
        }
        diagnosticManager.cleanup()
        var expected: [(Int, Double, Double)] = []
        var audio: [Float] = []
        // Two passes test recurrence, rather than merely the ability to create clusters.
        for index in [0, 1, 2, 0, 1, 2] {
            let start = Double(audio.count) / 16000
            audio += voices[index]
            expected.append((index, start, Double(audio.count) / 16000))
            audio += [Float](repeating: 0, count: 16000)
        }
        let overlapStart = Double(audio.count) / 16000
        let length = min(voices[0].count, voices[1].count)
        audio += (0..<length).map { (voices[0][$0] + voices[1][$0]) * 0.5 }
        let overlapEnd = Double(audio.count) / 16000
        audio += [Float](repeating: 0, count: 32000)
        var microphone = [Float](repeating: 0, count: audio.count)
        var meeting = audio
        for (_, start, end) in expected.suffix(3) {
            let lower = Int((start * 16000).rounded()), upper = Int((end * 16000).rounded())
            microphone.replaceSubrange(lower..<upper, with: audio[lower..<upper])
            meeting.replaceSubrange(lower..<upper, with: repeatElement(Float(0), count: upper - lower))
        }
        // Match production: two sources and actual 8-second disk chunks, with tail.
        for (source, samples) in [(AudioSource.meeting, meeting), (.microphone, microphone)] {
            for offset in stride(from: 0, to: samples.count, by: 128000) {
                let slice = Array(samples[offset..<min(offset + 128000, samples.count)])
                let filename = "\(source.rawValue)-\(offset).wav"
                try WaveFile.encode(slice).write(to: store.fileURL(session.id, filename: filename))
                session.chunks.append(AudioChunk(source: source, start: Double(offset) / 16000,
                    duration: Double(slice.count) / 16000, filename: filename))
            }
        }
        let started = Date()
        let turns = try await LocalDiarizer().process(session: session, store: store)
        session.applySpeakerTurns(turns)
        for turn in turns {
            print("TURN \(turn.source.rawValue) \(String(format: "%.2f", turn.start))..\(String(format: "%.2f", turn.end)) label=\(turn.speakerID ?? "unknown") quality=\(turn.confidence) overlap=\(turn.isOverlap)")
        }
        guard !turns.isEmpty else { throw CopilotError.message("FAIL: local diarizer returned no speech") }
        var labels: [Int: [String?]] = [:]
        for (position, item) in expected.enumerated() {
            let (index, start, end) = item
            let line = TranscriptLine(source: position < 3 ? .meeting : .microphone, start: start + 1, end: end - 0.5, text: "synthetic")
            labels[index, default: []].append(session.speakerID(for: line))
        }
        let overlap = TranscriptLine(source: .meeting, start: overlapStart + 1, end: overlapEnd - 0.5, text: "overlap")
        print("SPEAKERS: \(turns.count) turns, \(Set(turns.compactMap(\.speakerID)).count) clusters, \(String(format: "%.2f", Date().timeIntervalSince(started))) seconds for \(String(format: "%.2f", Double(audio.count) / 16000)) seconds audio")
        for index in 0..<3 { print("VOICE \(phrases[index].0): \(labels[index, default: []].map { $0 ?? "unknown" })") }
        print("OVERLAP: marked \(turns.filter { $0.isOverlap && $0.start < overlapEnd && $0.end > overlapStart }.count), assigned \(session.speakerID(for: overlap) ?? "unknown")")
        let unknown = TranscriptLine(source: .meeting, start: Double(audio.count) / 16000 - 1, end: Double(audio.count) / 16000, text: "silence")
        guard session.speakerID(for: unknown) == nil else { throw CopilotError.message("FAIL: silence received speaker identity") }
        let consistent = (0..<3).allSatisfy { index in
            let values = labels[index, default: []]
            return values.count == 2 && values[0] != nil && values[0] == values[1]
        }
        let separated = Set((0..<3).compactMap { labels[$0]?.first ?? nil }).count == 3
        print("MEASURED: recurring voice consistency=\(consistent), three-voice separation=\(separated), overlap uncertain=\(session.speakerID(for: overlap) == nil)")
        // Measurement is reported separately from execution: model execution does not prove diarization quality.
        print("PASS: actual local Core ML inference and synthetic unknown-region check; see measured quality above")
    }

    private static func command(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CopilotError.message("Synthetic voice command failed: \(executable)") }
    }
}
