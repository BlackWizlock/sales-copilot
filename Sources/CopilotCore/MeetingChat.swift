import Foundation

public struct MeetingQuestionContext {
    public let selectedLines: [TranscriptLine]
    public let prompt: String
    public let questionTooLarge: Bool
    public init(session: MeetingSession, question: String, recentQuestions: [String]) {
        let lines = TranscriptDeduplicator.visible(session.transcript)
        let input = lines.map { "[\($0.id.uuidString) @ \(Int($0.start))s]\n\($0.source.title): \($0.text)" }.joined(separator: "\n\n")
        let context = PromptContext.retrieve(proposal: input, deal: "", latestUtterance: question, recentUtterances: recentQuestions)
        let selected = context.excerpts.map(\.text).joined(separator: "\n")
        selectedLines = lines.filter { $0.text.count <= 4_000 && selected.contains($0.id.uuidString) }
        questionTooLarge = context.questionTooLarge
        prompt = "Поиск выполнен по всей текущей транскрипции. Ниже только отобранные фразы. Отсутствие факта в выдержках не доказывает, что он не обсуждался. Если ответа нет, так и скажи.\n\n"
            + selectedLines.map { "[\($0.id.uuidString) @ \(Int($0.start))s] \($0.source.title): \($0.text)" }.joined(separator: "\n")
            + "\n\nПоследние вопросы пользователя (это вопросы, не источник фактов):\n" + context.question
    }
    public func validated(citations: [SummaryCitation]) -> [SummaryCitation] {
        var seen = Set<UUID>()
        return citations.filter { $0.isValid(in: selectedLines) && seen.insert($0.segmentID).inserted }
    }
}
public enum MeetingChatRole: String, Codable { case question, answer }
public enum MeetingChatState: String, Codable { case pending, completed, cancelled, failed }
public struct MeetingChatMessage: Codable, Identifiable {
    public var id = UUID()
    public var role: MeetingChatRole
    public var text: String
    public var citations: [SummaryCitation]
    public var fingerprint: String
    public var model: String
    public var created = Date()
    public var state: MeetingChatState = .completed
    public init(role: MeetingChatRole, text: String, citations: [SummaryCitation], fingerprint: String, model: String) {
        self.role = role; self.text = text; self.citations = citations; self.fingerprint = fingerprint; self.model = model
    }
}
public struct MeetingChatArchive: Codable {
    public var meetingID: UUID
    public var messages: [MeetingChatMessage] = []
    public init(meetingID: UUID) { self.meetingID = meetingID }
    public static func load(directory: URL, meetingID: UUID) throws -> Self {
        let url = try safeURL(directory)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 30_000_000 else { throw CopilotError.message("История чата слишком велика для загрузки") }
        let archive = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard archive.meetingID == meetingID else { throw CopilotError.message("Чат относится к другой встрече") }
        return archive
    }
    private static func safeURL(_ directory: URL) throws -> URL {
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CopilotError.message("Недопустимая папка чата") }
        let url = directory.appendingPathComponent("chat.json")
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw CopilotError.message("Недопустимая ссылка чата") }
        return url
    }
    public func save(directory: URL) throws {
        let url = try Self.safeURL(directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".chat-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CopilotError.message("Не удалось сохранить чат") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try JSONEncoder().encode(self).write(to: temporary)
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
