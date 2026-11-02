import Foundation
import Darwin

public struct MCPAccessPolicy: Codable, Equatable {
    public var enabled = false
    public var allowedMeetings: Set<UUID> = []
    public init() {}
}
public enum MCPArchiveError: LocalizedError {
    case unavailable, invalidArguments
    public var errorDescription: String? { self == .unavailable ? "Встреча недоступна" : "Недопустимые параметры" }
}
public final class MCPAccessStore {
    public let root: URL
    public init(root: URL) { self.root = root }
    private var policyURL: URL { root.appendingPathComponent("mcp-access.json") }
    public func load() throws -> MCPAccessPolicy {
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MCPArchiveError.unavailable }
        guard FileManager.default.fileExists(atPath: policyURL.path) else { return MCPAccessPolicy() }
        guard try policyURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]).isSymbolicLink != true else { throw MCPArchiveError.unavailable }
        return try JSONDecoder().decode(MCPAccessPolicy.self, from: Data(contentsOf: policyURL))
    }
    private func save(_ policy: MCPAccessPolicy) throws {
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? policyURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw MCPArchiveError.unavailable }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try JSONEncoder().encode(policy).write(to: policyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: policyURL.path)
    }
    public func setEnabled(_ enabled: Bool) throws {
        var p = (try? load()) ?? MCPAccessPolicy(); p.enabled = enabled; try save(p)
    }
    public func setAllowed(_ id: UUID, allowed: Bool) throws {
        var p = try load()
        if allowed { p.allowedMeetings.insert(id) } else { p.allowedMeetings.remove(id) }
        try save(p)
    }
}
public struct MCPPage<T: Codable>: Codable {
    public var items: [T]
    public var nextOffset: Int?
    public init(items: [T], nextOffset: Int?) { self.items = items; self.nextOffset = nextOffset }
}
public struct MCPMeetingInfo: Codable {
    public var id: UUID
    public var title: String
    public var created: Date
    public var state: SessionState
    public var transcriptLines: Int
    public var audioChunks: Int
    public var duration: Double
    public var excerpt: String?
    public init(_ s: MeetingSession, excerpt: String? = nil) {
        id = s.id; title = String(s.title.prefix(500)); created = s.created; state = s.state
        transcriptLines = s.transcript.count; audioChunks = s.chunks.count
        duration = s.chunks.map { $0.start + $0.duration }.max() ?? 0
        self.excerpt = excerpt
    }
}
/// Inclusive creation-time bounds and an exact ID from the local CRM snapshot only.
public struct MCPMeetingFilter {
    public let from: Date?
    public let to: Date?
    public let dealID: String?
    public init(from: String? = nil, to: String? = nil, dealID: String? = nil) throws {
        func date(_ value: String?) throws -> Date? {
            guard let value else { return nil }
            guard value.count <= 40,
                  value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil else { throw MCPArchiveError.invalidArguments }
            // ISO8601DateFormatter normalizes invalid days and 24:00; reject those first.
            let parts = value.prefix(19).split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
            guard parts.count == 6, (1...9999).contains(parts[0]), (1...12).contains(parts[1]),
                  (0...23).contains(parts[3]), (0...59).contains(parts[4]), (0...59).contains(parts[5]) else { throw MCPArchiveError.invalidArguments }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5])
            guard let day = calendar.date(from: components),
                  calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: day) == components else { throw MCPArchiveError.invalidArguments }
            if !value.hasSuffix("Z") {
                let zone = value.suffix(5).split(separator: ":").compactMap { Int($0) }
                guard zone.count == 2, zone[0] <= 23, zone[1] <= 59 else { throw MCPArchiveError.invalidArguments }
            }
            let parser = ISO8601DateFormatter()
            parser.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
            guard let date = parser.date(from: value) else { throw MCPArchiveError.invalidArguments }
            return date
        }
        self.from = try date(from); self.to = try date(to)
        if let from = self.from, let to = self.to, from > to { throw MCPArchiveError.invalidArguments }
        if let dealID {
            guard dealID.range(of: #"^[1-9][0-9]{0,18}$"#, options: .regularExpression) != nil,
                  Int64(dealID) != nil else { throw MCPArchiveError.invalidArguments }
        }
        self.dealID = dealID
    }
}

/// Fixed local journal. Never accepts paths or content from an MCP request.
public final class MCPAuditStore {
    public static let maximumBytes = 64 * 1024
    private let root: URL
    public init(root: URL) { self.root = root }
    public func record(tool: String, meetingID: UUID? = nil, outcome: String, count: Int) throws {
        let tools = ["meeting_list", "meeting_search", "meeting_get", "meeting_transcript", "meeting_summary", "meeting_deal"]
        guard tools.contains(tool), ["success", "denied", "response_too_large"].contains(outcome), count >= 0 else { throw MCPArchiveError.invalidArguments }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw MCPArchiveError.unavailable }
        defer { close(directory) }
        let fd = openat(directory, "mcp-audit.jsonl", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MCPArchiveError.unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw MCPArchiveError.unavailable }
        defer { flock(fd, LOCK_UN) }
        guard fchmod(fd, 0o600) == 0 else { throw MCPArchiveError.unavailable }
        var entry: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()), "tool": tool, "outcome": outcome, "count": count]
        if outcome == "success", let meetingID { entry["meetingID"] = meetingID.uuidString }
        var row = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]); row.append(10)
        // Retain only complete recent rows, even if an earlier crash left a partial row.
        let size = lseek(fd, 0, SEEK_END)
        guard size >= 0, lseek(fd, max(0, size - off_t(Self.maximumBytes)), SEEK_SET) >= 0 else { throw MCPArchiveError.unavailable }
        var bytes = [UInt8](repeating: 0, count: Self.maximumBytes)
        let length = Darwin.read(fd, &bytes, bytes.count)
        guard length >= 0 else { throw MCPArchiveError.unavailable }
        var data = Data(bytes.prefix(length))
        if size > Self.maximumBytes, let newline = data.firstIndex(of: 10) { data.removeSubrange(...newline) }
        if data.last != 10 { data = Data() }
        while data.count + row.count > Self.maximumBytes {
            guard let newline = data.firstIndex(of: 10) else { data = Data(); break }
            data.removeSubrange(...newline)
        }
        data.append(row)
        guard lseek(fd, 0, SEEK_SET) == 0, ftruncate(fd, 0) == 0 else { throw MCPArchiveError.unavailable }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                guard n > 0 else { throw MCPArchiveError.unavailable }; written += n
            }
        }
        guard fsync(fd) == 0 else { throw MCPArchiveError.unavailable }
    }
}
/// Read-only archive. Every operation reloads policy, including calls made in an existing MCP connection.
public final class MCPArchive {
    public let root: URL
    private let access: MCPAccessStore
    public init(root: URL) { self.root = root; access = MCPAccessStore(root: root) }
    private func policy() -> MCPAccessPolicy { (try? access.load()) ?? MCPAccessPolicy() }
    private func page<T: Codable>(_ items: [T], offset: Int, limit: Int) throws -> MCPPage<T> {
        guard offset >= 0, (1...50).contains(limit), offset <= 1_000_000 else { throw MCPArchiveError.invalidArguments }
        let start = min(offset, items.count), end = min(start + limit, items.count)
        return MCPPage(items: Array(items[start..<end]), nextOffset: end < items.count ? end : nil)
    }
    private func checkedURL(_ id: UUID, filename: String) throws -> URL {
        // Mirror SessionStore.fileURL guards without invoking SessionStore.init or recovery mutations.
        let p = policy()
        guard p.enabled, p.allowedMeetings.contains(id), !filename.isEmpty,
              filename == (filename as NSString).lastPathComponent, filename != ".", filename != "..",
              try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MCPArchiveError.unavailable }
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let info = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard info.isSymbolicLink != true, info.isDirectory == true else { throw MCPArchiveError.unavailable }
        let url = directory.appendingPathComponent(filename)
        let file = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard file.isSymbolicLink != true, file.isRegularFile == true, (file.fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw MCPArchiveError.unavailable }
        return url
    }
    public func session(_ id: UUID) throws -> MeetingSession {
        do {
            let value = try JSONDecoder().decode(MeetingSession.self, from: Data(contentsOf: checkedURL(id, filename: "session.json")))
            guard value.id == id else { throw MCPArchiveError.unavailable }
            return value
        } catch { throw MCPArchiveError.unavailable }
    }
    private func filteredSessions(_ filter: MCPMeetingFilter) -> [MeetingSession] {
        let p = policy()
        guard p.enabled else { return [] }
        return p.allowedMeetings.compactMap { try? session($0) }.filter { session in
            if let from = filter.from, session.created < from { return false }
            if let to = filter.to, session.created > to { return false }
            if let dealID = filter.dealID {
                guard let snapshot = try? deal(session.id), snapshot.dealID == dealID else { return false }
            }
            return true
        }.sorted { $0.created == $1.created ? $0.id.uuidString < $1.id.uuidString : $0.created > $1.created }
    }
    public func list(offset: Int, limit: Int, filter: MCPMeetingFilter? = nil) throws -> MCPPage<MCPMeetingInfo> {
        try page(filteredSessions(try filter ?? MCPMeetingFilter()).map { MCPMeetingInfo($0) }, offset: offset, limit: limit)
    }
    public func transcript(_ id: UUID, offset: Int, limit: Int) throws -> MCPPage<TranscriptLine> {
        let s = try session(id)
        return try page(s.transcript.sorted { $0.start < $1.start }, offset: offset, limit: limit)
    }
    public func search(_ query: String, offset: Int, limit: Int, filter: MCPMeetingFilter? = nil) throws -> MCPPage<MCPMeetingInfo> {
        guard !query.isEmpty, query.count <= 500 else { throw MCPArchiveError.invalidArguments }
        let result = filteredSessions(try filter ?? MCPMeetingFilter()).compactMap { s -> MCPMeetingInfo? in
            let found = s.transcript.first { $0.text.localizedCaseInsensitiveContains(query) }
            guard s.title.localizedCaseInsensitiveContains(query) || found != nil else { return nil }
            return MCPMeetingInfo(s, excerpt: found.map { "[\(String(format: "%.1f", $0.start))s] " + String($0.text.prefix(400)) })
        }
        return try page(result, offset: offset, limit: limit)
    }
    public func summary(_ id: UUID) throws -> CRMValue {
        _ = try session(id)
        do {
            let value = try JSONDecoder().decode(CRMValue.self, from: Data(contentsOf: checkedURL(id, filename: "intelligence.json")))
            // Never return the full intelligence record: it can include private drafts and model configuration.
            return value.object["summary"] ?? .null
        } catch { return .null }
    }
    public func deal(_ id: UUID) throws -> DealContext? {
        _ = try session(id)
        let directory = root.appendingPathComponent("crm", isDirectory: true)
        do {
            let info = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard info.isSymbolicLink != true, info.isDirectory == true else { throw MCPArchiveError.unavailable }
            let file = directory.appendingPathComponent("\(id.uuidString)-deal.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let v = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard v.isSymbolicLink != true, v.isRegularFile == true, (v.fileSize ?? Int.max) <= 8 * 1024 * 1024 else { throw MCPArchiveError.unavailable }
            return try JSONDecoder().decode(DealContext.self, from: Data(contentsOf: file))
        } catch { throw MCPArchiveError.unavailable }
    }
}
