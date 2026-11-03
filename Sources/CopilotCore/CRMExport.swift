import Foundation
import CryptoKit

public struct CRMExportPreview: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var portal: String
    public var dealID: String
    public var dealTitle: String
    public var title: String
    public var started: Date
    public var ended: Date
    public var summary: String
    public var transcript: String
    public var audioName: String?
    public var audioSHA256: String?
    public var audioBytes: Int
    public var fingerprint: String
    public init(session: MeetingSession, context: DealContext, summary: String, audioURL: URL?) throws {
        guard BitrixPortal.isAllowed(context.portal), Int(context.dealID).map({ $0 > 0 }) == true else { throw CopilotError.message("Выберите сделку разрешённого портала") }
        guard session.state != .recording && session.state != .processing, !session.transcript.isEmpty else { throw CopilotError.message("Дождитесь завершения записи и транскрипции") }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CopilotError.message("Добавьте и проверьте итоги встречи") }
        let audio = try Self.audioData(audioURL)
        meetingID = session.id; portal = context.portal; dealID = context.dealID; dealTitle = context.title; title = session.title
        started = session.created; ended = session.ended ?? session.created
        self.summary = summary; transcript = Self.transcriptText(session)
        audioName = audioURL?.lastPathComponent; audioBytes = audio?.count ?? 0
        audioSHA256 = audio.map { Self.sha256($0) }
        fingerprint = Self.digest(session: session, summary: summary, audio: audio)
    }
    public func matches(session: MeetingSession, summary: String, audioURL: URL?) throws -> Bool {
        let audio = try Self.audioData(audioURL)
        return meetingID == session.id && fingerprint == Self.digest(session: session, summary: summary, audio: audio)
    }
    public static func transcriptText(_ session: MeetingSession) -> String {
        TranscriptDeduplicator.visible(session.transcript).map { line in
            let name = session.speakerID(for: line).flatMap { id in session.speakers?.first { $0.id == id }?.name }
            return "[\(String(format: "%.1f", line.start))] \(name ?? line.source.title): \(line.text)"
        }.joined(separator: "\n")
    }
    private static func digest(session: MeetingSession, summary: String, audio: Data?) -> String {
        let payload = [session.id.uuidString, session.title, String(session.created.timeIntervalSince1970), String((session.ended ?? session.created).timeIntervalSince1970), summary, transcriptText(session), audio.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "no-audio"].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func audioData(_ url: URL?) throws -> Data? {
        guard let url else { return nil }
        let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard url.isFileURL, url.pathExtension.lowercased() == "m4a", v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize, size > 0, size <= 50 * 1024 * 1024 else {
            throw CopilotError.message("Нужен обычный M4A размером до 50 МБ. При большем размере сохраните текст без аудио явно.")
        }
        return try Data(contentsOf: url)
    }
}

public enum CRMExportState: String, Codable, Sendable { case prepared, sending, needsReconciliation, completed, rejected }
public struct CRMExport: Codable, Equatable, Sendable {
    public var operationID: UUID
    public var preview: CRMExportPreview
    public var state: CRMExportState
    public var activityID: String?
    public var updated: Date
    public init(preview: CRMExportPreview) { operationID = UUID(); self.preview = preview; state = .prepared; updated = Date() }
    public var activityDescription: String { preview.summary + "\n\nТранскрипция во вложении.\nID экспорта: " + marker }
    public var marker: String { "axis-copilot-\(preview.meetingID.uuidString.lowercased())" }
    public var resultURL: URL? {
        guard activityID != nil else { return nil }
        return URL(string: "https://\(preview.portal)/crm/deal/details/\(preview.dealID)/")
    }
}

/// Private, per-meeting sidecars; never alter the recording manifest or persist credentials.
public final class CRMJournal {
    public let root: URL
    public init(root: URL) throws {
        self.root = root
        if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw CopilotError.message("Ссылка вместо папки CRM") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    private func url(_ id: UUID, _ suffix: String) throws -> URL {
        let u = root.appendingPathComponent("\(id.uuidString)-\(suffix).json")
        if (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw CopilotError.message("Ссылка вместо файла CRM") }
        return u
    }
    private func write<T: Encodable>(_ object: T, _ url: URL) throws {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        try e.encode(object).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    public func bind(_ context: DealContext, meetingID: UUID) throws {
        if let existing = try self.context(meetingID: meetingID), existing.dealID != context.dealID || existing.portal != context.portal { throw CopilotError.message("У встречи уже другая сделка. Исходная привязка сохранена.") }
        try write(context, url(meetingID, "deal"))
    }
    public func context(meetingID: UUID) throws -> DealContext? { try read(DealContext.self, url(meetingID, "deal")) }
    public func save(_ operation: CRMExport) throws { try write(operation, url(operation.preview.meetingID, "export")) }
    public func operation(meetingID: UUID) throws -> CRMExport? {
        var value = try read(CRMExport.self, url(meetingID, "export"))
        if value?.state == .sending { value?.state = .needsReconciliation }
        return value
    }
}
