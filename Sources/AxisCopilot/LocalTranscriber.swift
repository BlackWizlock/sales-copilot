import Foundation
import CopilotCore
import FluidAudio
import CoreML

struct LocalTranscriber {
    let executable: URL
    let model: URL
    let engine: ASREngine
    let language: String
    let selectionVerified: Bool

    init(executable: URL, model: URL, engine: ASREngine = .whisper, language: String = "ru", selectionVerified: Bool = true) {
        self.executable = executable; self.model = model; self.engine = engine
        self.selectionVerified = selectionVerified
        self.language = ["ru", "en", "auto"].contains(language) ? language : "ru"
    }
    @MainActor static func selected(executable: URL, fallbackModel: URL) -> LocalTranscriber {
        let defaults = UserDefaults.standard
        let selected = ASRCatalog.models.first { $0.id == defaults.string(forKey: "asrModelID") }
        let path = defaults.string(forKey: "asrModelPath").map { URL(fileURLWithPath: $0).standardizedFileURL }
        let own = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AxisSalesCopilot/Models/ASR").path + "/"
        let shared = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml")
        let safePath = path.flatMap { $0.path.hasPrefix(own) || (selected?.engine == .parakeet && $0 == shared) || $0 == defaultModel ? $0 : nil }
        return LocalTranscriber(executable: executable, model: safePath ?? fallbackModel,
                                engine: safePath == nil ? .whisper : selected?.engine ?? .whisper,
                                language: defaults.string(forKey: "asrLanguage") ?? "ru",
                                selectionVerified: path == nil || (selected.map { ASRModelManager.verifiedPaths[$0.id] == safePath } ?? false))
    }

    static var defaultModel: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Models/ggml-small.bin"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AxisSalesCopilot/Models/ggml-small.bin")
    }
    static var defaultExecutable: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Tools/whisper-cli"),
           FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli")
    }
    func validate() throws {
        guard selectionVerified else { throw CopilotError.message(L10n.string("Дождитесь проверки выбранной модели в настройках. Если модель недоступна, выберите установленную модель заново.")) }
        if engine == .parakeet {
            for root in ASRCatalog.models.first(where: { $0.engine == .parakeet })!.requiredRoots {
                let item = model.appendingPathComponent(root)
                guard FileManager.default.fileExists(atPath: item.path), item.standardizedFileURL == item.resolvingSymlinksInPath() else {
                    throw CopilotError.message(L10n.string("Сначала загрузите и проверьте модель Parakeet v3 в настройках."))
                }
            }
            return
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw CopilotError.message(L10n.string("Не найден whisper-cli. Укажите локальный исполняемый файл в настройках.")) }
        let attributes = try FileManager.default.attributesOfItem(atPath: model.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 > 1_000_000 else { throw CopilotError.message(L10n.string("Выберите загруженную многоязычную модель Whisper .bin")) }
    }
    func transcribe(url: URL, chunk: AudioChunk) async throws -> [TranscriptLine] {
        try validate()
        if engine == .parakeet {
            let text = try await LocalParakeet.shared.transcribe(url, directory: model)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            var line = TranscriptLine(source: chunk.source, start: chunk.start, end: chunk.start + chunk.duration, text: trimmed)
            line.chunkID = chunk.id
            return [line]
        }
        return try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            let outputBase = url.deletingPathExtension().appendingPathExtension("transcription")
            let logURL = url.deletingPathExtension().appendingPathExtension("log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            process.arguments = ["-m", model.path, "-l", language, "-f", url.path, "-oj", "-of", outputBase.path, "-np", "-t", "8", "-bo", "1", "-bs", "1"]
            process.standardOutput = log; process.standardError = log
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            let killTimeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
            DispatchQueue.global().asyncAfter(deadline: .now() + 123, execute: killTimeout)
            process.waitUntilExit()
            timeout.cancel(); killTimeout.cancel()
            guard process.terminationStatus == 0 else {
                throw CopilotError.message(L10n.format("Локальное распознавание завершилось с кодом %@. Аудио сохранено; можно повторить обработку.", String(describing: process.terminationStatus)))
            }
            let data = try Data(contentsOf: outputBase.appendingPathExtension("json"))
            var lines = try WhisperOutput.parse(data, offset: chunk.start, source: chunk.source)
            for i in lines.indices { lines[i].chunkID = chunk.id; lines[i].end = min(lines[i].end, chunk.start + chunk.duration) }
            return lines
        }.value
    }
}


/// Explicit CoreML loading avoids FluidAudio's cache recovery, which can delete shared models
/// and fetch replacements. Inference never invokes a downloader or mutates another app's cache.
private actor LocalParakeet {
    static let shared = LocalParakeet()
    private var manager: AsrManager?
    private var loadedDirectory: URL?
    private var working = false
    func transcribe(_ url: URL, directory: URL) async throws -> String {
        guard !working else { throw CopilotError.message(L10n.string("Модель Parakeet уже обрабатывает фрагмент.")) }
        working = true
        defer { working = false }
        if loadedDirectory != directory || manager == nil {
            func load(_ filename: String, units: MLComputeUnits) throws -> MLModel {
                let config = MLModelConfiguration(); config.computeUnits = units
                return try MLModel(contentsOf: directory.appendingPathComponent(filename), configuration: config)
            }
            let config = MLModelConfiguration(); config.computeUnits = .cpuAndNeuralEngine
            let data = try Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json"))
            let dictionary = try JSONDecoder().decode([String: String].self, from: data)
            var vocabulary: [Int: String] = [:]
            for (key, value) in dictionary { if let id = Int(key) { vocabulary[id] = value } }
            guard !vocabulary.isEmpty else { throw CopilotError.message(L10n.string("Повреждён словарь Parakeet.")) }
            let models = try AsrModels(encoder: load("Encoder.mlmodelc", units: .cpuAndNeuralEngine),
                                       preprocessor: load("Preprocessor.mlmodelc", units: .cpuOnly),
                                       decoder: load("Decoder.mlmodelc", units: .cpuAndNeuralEngine),
                                       joint: load("JointDecision.mlmodelc", units: .cpuAndNeuralEngine),
                                       configuration: config, vocabulary: vocabulary, version: .v3)
            let candidate = AsrManager(config: .default)
            try await candidate.initialize(models: models)
            manager = candidate; loadedDirectory = directory
        }
        guard let manager else { throw CopilotError.message(L10n.string("Не удалось загрузить Parakeet.")) }
        var wave = try WaveFile.decode(Data(contentsOf: url))
        guard wave.sampleRate == 16000 else { throw CopilotError.message(L10n.string("Для Parakeet нужен локальный фрагмент 16 кГц.")) }
        if wave.samples.count < 16000 { wave.samples += Array(repeating: 0, count: 16000 - wave.samples.count) }
        return try await manager.transcribe(wave.samples).text
    }
}
