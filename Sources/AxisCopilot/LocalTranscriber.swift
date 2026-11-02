import Foundation
import CopilotCore

struct LocalTranscriber {
    let executable: URL
    let model: URL

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
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw CopilotError.message("Не найден whisper-cli. Укажите локальный исполняемый файл в настройках.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: model.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 > 1_000_000 else { throw CopilotError.message("Выберите загруженную многоязычную модель Whisper .bin") }
    }
    func transcribe(url: URL, chunk: AudioChunk) async throws -> [TranscriptLine] {
        try validate()
        return try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            let outputBase = url.deletingPathExtension().appendingPathExtension("transcription")
            let logURL = url.deletingPathExtension().appendingPathExtension("log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            process.arguments = ["-m", model.path, "-l", "ru", "-f", url.path, "-oj", "-of", outputBase.path, "-np", "-t", "8", "-bo", "1", "-bs", "1"]
            process.standardOutput = log; process.standardError = log
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            let killTimeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
            DispatchQueue.global().asyncAfter(deadline: .now() + 123, execute: killTimeout)
            process.waitUntilExit()
            timeout.cancel(); killTimeout.cancel()
            guard process.terminationStatus == 0 else {
                throw CopilotError.message("Локальное распознавание завершилось с кодом \(process.terminationStatus). Аудио сохранено; можно повторить обработку.")
            }
            let data = try Data(contentsOf: outputBase.appendingPathExtension("json"))
            var lines = try WhisperOutput.parse(data, offset: chunk.start, source: chunk.source)
            for i in lines.indices { lines[i].chunkID = chunk.id; lines[i].end = min(lines[i].end, chunk.start + chunk.duration) }
            return lines
        }.value
    }
}
