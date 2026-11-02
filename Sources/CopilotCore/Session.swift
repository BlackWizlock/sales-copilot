import Foundation

public enum AudioSource: String, Codable, CaseIterable {
    case microphone, meeting
    public var title: String { self == .microphone ? "Микрофон" : "Звук встречи" }
}
public enum SessionState: String, Codable { case recording, processing, completed, interrupted }
public enum ChunkState: String, Codable { case pending, completed, failed }

public struct AudioChunk: Codable, Identifiable {
    public var id = UUID()
    public var source: AudioSource
    public var start: Double
    public var duration: Double
    public var filename: String
    public var rms: Float
    public var state: ChunkState = .pending
    public var error: String?
    public init(source: AudioSource, start: Double, duration: Double, filename: String, rms: Float = 1) {
        self.source = source; self.start = start; self.duration = duration
        self.filename = filename; self.rms = rms
    }
}
public struct TranscriptLine: Codable, Identifiable {
    public var id = UUID()
    public var chunkID: UUID?
    public var source: AudioSource
    public var start: Double
    public var end: Double
    public var text: String
    public init(source: AudioSource, start: Double, end: Double, text: String) {
        self.source = source; self.start = start; self.end = end; self.text = text
    }
}
public struct MeetingSession: Codable, Identifiable {
    public var id = UUID()
    public var title: String
    public var created = Date()
    public var ended: Date?
    public var state: SessionState = .recording
    public var sourceName = ""
    public var chunks: [AudioChunk] = []
    public var transcript: [TranscriptLine] = []
    public var issues: [String] = []
    public var speakers: [SpeakerProfile]?
    public var speakerTurns: [SpeakerTurn]?
    public var speakerOverrides: [SpeakerOverride]?
    public init(title: String) { self.title = title }
}
public enum CopilotError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

public final class SessionStore {
    public let root: URL
    public private(set) var loadWarnings: [String] = []
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    public func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func fileURL(_ id: UUID, filename: String) throws -> URL {
        guard !filename.isEmpty, filename == (filename as NSString).lastPathComponent,
              !filename.contains("/"), filename != ".", filename != ".." else {
            throw CopilotError.message("Недопустимое имя файла")
        }
        if try directory(id).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw CopilotError.message("Символическая ссылка вместо папки встречи")
        }
        let url = directory(id).appendingPathComponent(filename)
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw CopilotError.message("Символические ссылки не поддерживаются")
        }
        return url
    }
    public func create(title: String) throws -> MeetingSession {
        let session = MeetingSession(title: title)
        try FileManager.default.createDirectory(at: directory(session.id), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try save(session)
        return session
    }
    public func save(_ session: MeetingSession) throws {
        let url = try fileURL(session.id, filename: "session.json")
        try encoder.encode(session).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func loadAll() throws -> [MeetingSession] {
        loadWarnings = []
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .creationDateKey])
        var sessions: [MeetingSession] = []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            do {
                let values = try folder.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .creationDateKey])
                guard values.isSymbolicLink != true, values.isDirectory == true else { continue }
                var item: MeetingSession
                var manifestRecovered = false
                do {
                    item = try JSONDecoder().decode(MeetingSession.self, from: Data(contentsOf: fileURL(id, filename: "session.json")))
                    guard item.id == id else { throw CopilotError.message("Неверный идентификатор встречи") }
                } catch {
                    loadWarnings.append("Не прочитан манифест \(id): \(error.localizedDescription)")
                    item = MeetingSession(title: "Восстановленная встреча")
                    item.id = id; item.state = .interrupted
                    item.created = values.creationDate ?? Date()
                    manifestRecovered = true
                }
                if item.state == .recording || item.state == .processing { item.state = .interrupted }
                let known = Set(item.chunks.map(\.filename))
                for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) where url.pathExtension == "wav" && !known.contains(url.lastPathComponent) {
                    do {
                        let pieces = url.deletingPathExtension().lastPathComponent.split(separator: "-")
                        guard pieces.count >= 3, let source = AudioSource(rawValue: String(pieces[0])), let milliseconds = Double(pieces[1]), milliseconds.isFinite, milliseconds >= 0,
                              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
                        let wave = try WaveFile.decode(Data(contentsOf: url))
                        guard wave.sampleRate == 16000, !wave.samples.isEmpty else { continue }
                        let rms = sqrt(wave.samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(wave.samples.count))
                        item.chunks.append(AudioChunk(source: source, start: milliseconds / 1000, duration: Double(wave.samples.count) / 16000, filename: url.lastPathComponent, rms: rms))
                        item.state = .interrupted
                    } catch {
                        let message = "Повреждён аудиофрагмент \(url.lastPathComponent): \(error.localizedDescription)"
                        item.issues.append(message); loadWarnings.append(message)
                    }
                }
                if !manifestRecovered || !item.chunks.isEmpty { sessions.append(item) }
            } catch {
                loadWarnings.append("Не прочитана встреча \(id): \(error.localizedDescription)")
            }
        }
        return sessions.sorted { $0.created > $1.created }
    }
}
