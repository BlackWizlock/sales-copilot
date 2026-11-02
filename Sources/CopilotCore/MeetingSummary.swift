import Foundation

public struct SummaryCitation: Codable, Identifiable {
    public var id: UUID { segmentID }
    public var segmentID: UUID
    public var seconds: Double
    public var quote: String
    public init(segmentID: UUID, seconds: Double, quote: String) { self.segmentID = segmentID; self.seconds = seconds; self.quote = quote }
    public func isValid(in lines: [TranscriptLine]) -> Bool {
        lines.contains { $0.id == segmentID && abs($0.start - seconds) < 0.01 && !$0.text.isEmpty && $0.text.contains(quote) && !quote.isEmpty }
    }
}
public struct MeetingSummary: Codable {
    public var text: String
    public var transcriptFingerprint: String
    public var model: String
    public var generatedAt: Date
    public var citations: [SummaryCitation]
    public init(text: String, transcriptFingerprint: String, model: String, citations: [SummaryCitation]) {
        self.text = text; self.transcriptFingerprint = transcriptFingerprint; self.model = model; self.generatedAt = Date(); self.citations = citations
    }
}
public struct SupportMaterial: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var text: String
    public init(id: UUID = UUID(), name: String, text: String) { self.id = id; self.name = name; self.text = text }
}

public struct IntelligenceRecord: Codable {
    public var proposalName = ""
    public var proposalText = ""
    public var dealText = ""
    public var summary: MeetingSummary?
    public var materials: [SupportMaterial]?
    public init() {}
    public var supportMaterials: [SupportMaterial] {
        if let materials { return materials }
        guard !proposalText.isEmpty else { return [] }
        return [SupportMaterial(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: proposalName, text: proposalText)]
    }
    public mutating func addMaterials(_ incoming: [SupportMaterial]) throws {
        var combined = supportMaterials
        for item in incoming {
            guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CopilotError.message("В документе нет распознанного текста.") }
            guard item.text.count <= 60_000 else { throw CopilotError.message("Документ слишком большой. Добавьте выдержку до 60 000 символов.") }
            if !combined.contains(where: { $0.name == item.name && $0.text == item.text }) { combined.append(item) }
        }
        guard combined.count <= 12, combined.reduce(0, { $0 + $1.text.count }) <= 240_000 else {
            throw CopilotError.message("Можно добавить до 12 документов общим объёмом до 240 000 символов.")
        }
        setMaterials(combined)
    }
    public mutating func removeMaterial(id: UUID) { setMaterials(supportMaterials.filter { $0.id != id }) }
    private mutating func setMaterials(_ values: [SupportMaterial]) {
        materials = values
        proposalName = values.map(\.name).joined(separator: ", ")
        proposalText = values.map { "Документ: \($0.name)\n\($0.text)" }.joined(separator: "\n\n")
    }
    public static func load(directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("intelligence.json")
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw CopilotError.message("Недопустимая ссылка") }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    public func save(directory: URL) throws {
        guard try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isSymbolicLink != true else { throw CopilotError.message("Недопустимая папка") }
        let url = directory.appendingPathComponent("intelligence.json")
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw CopilotError.message("Недопустимая ссылка") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Temporary file is private before rename; no interval with world-readable client text.
        let temporary = directory.appendingPathComponent(".intelligence-\(UUID().uuidString)")
        let data = try JSONEncoder().encode(self)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CopilotError.message("Не удалось создать файл резюме") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
