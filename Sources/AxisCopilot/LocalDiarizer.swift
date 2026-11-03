import Foundation
import CoreML
import FluidAudio
import CopilotCore

/// Post-meeting, on-device voice clustering. Source labels never imply identity.
struct LocalDiarizer {
    static var modelsDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["AXIS_SPEAKER_MODELS"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("SpeakerModels"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("REVISION").path) { return bundled }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AxisCopilot/SpeakerModels", isDirectory: true)
    }
    static var modelsAvailable: Bool {
        ["pyannote_segmentation.mlmodelc", "wespeaker_v2.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent($0).path)
        }
    }

    func process(session: MeetingSession, store: SessionStore) async throws -> [SpeakerTurn] {
        guard Self.modelsAvailable else {
            throw CopilotError.message(L10n.string("Модели голосов не установлены. Выполните scripts/setup-speakers.sh или установите комплект с моделями."))
        }
        return try await Task.detached(priority: .utility) {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            // This overload only opens local files. It has no download fallback.
            let models = try await DiarizerModels.load(
                localSegmentationModel: Self.modelsDirectory.appendingPathComponent("pyannote_segmentation.mlmodelc"),
                localEmbeddingModel: Self.modelsDirectory.appendingPathComponent("wespeaker_v2.mlmodelc"),
                configuration: configuration)
            let manager = DiarizerManager(config: DiarizerConfig(clusteringThreshold: 0.35, minSpeechDuration: 0.7))
            manager.initialize(models: models)
            defer { manager.cleanup() }
            var turns: [SpeakerTurn] = []
            for chunk in session.chunks.sorted(by: { $0.start == $1.start ? $0.source.rawValue < $1.source.rawValue : $0.start < $1.start }) {
                try Task.checkCancellation()
                guard chunk.start.isFinite, chunk.start >= 0, chunk.duration.isFinite, chunk.duration > 0 else {
                    throw CopilotError.message(L10n.string("Некорректное время аудиофрагмента"))
                }
                let audio = try WaveFile.decode(Data(contentsOf: store.fileURL(session.id, filename: chunk.filename)))
                guard audio.sampleRate == 16000 else { throw CopilotError.message(L10n.string("Для голосов нужен звук 16 кГц mono")) }
                guard !audio.samples.isEmpty else { continue }
                let result = try manager.performCompleteDiarization(audio.samples)
                for segment in result.segments {
                    let start = chunk.start + max(0, Double(segment.startTimeSeconds))
                    let end = chunk.start + min(Double(audio.samples.count) / 16000, Double(segment.endTimeSeconds))
                    guard end > start, start.isFinite, end.isFinite else { continue }
                    let quality = segment.qualityScore.isFinite ? min(1, max(0, segment.qualityScore)) : 0
                    turns.append(SpeakerTurn(source: chunk.source, start: start, end: end,
                        speakerID: quality >= 0.25 && !segment.speakerId.isEmpty ? segment.speakerId : nil,
                        confidence: quality))
                }
            }
            // A new cluster needs at least the upstream macOS minimum speech
            // evidence (4 seconds). Short noisy tails are not confirmed voices.
            var evidence: [String: Double] = [:]
            for turn in turns {
                if let id = turn.speakerID { evidence[id, default: 0] += turn.end - turn.start }
            }
            for index in turns.indices {
                if let id = turns[index].speakerID,
                   evidence[id, default: 0] < Double(SpeakerUtilities.AssignmentConfig.macOS.minSpeakerDuration) {
                    turns[index].speakerID = nil
                }
            }
            // Preserve concurrent segments as uncertainty, including cross-source speech.
            for index in turns.indices {
                turns[index].isOverlap = turns.indices.contains { other in
                    other != index && turns[other].speakerID != turns[index].speakerID &&
                    min(turns[index].end, turns[other].end) - max(turns[index].start, turns[other].start) > 0.15
                }
            }
            return turns.sorted { $0.start < $1.start }
        }.value
    }
}
