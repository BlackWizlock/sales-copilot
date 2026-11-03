import Foundation

/// Organization metadata never moves or deletes a recording directory.
public struct MeetingLibrary: Codable {
    public struct Folder: Codable, Identifiable {
        public var id: UUID
        public var name: String
    }
    public enum Sort: String, CaseIterable { case newest, oldest, title }
    public enum ValidationError: Error { case invalidName, duplicateName, missingFolder }
    public private(set) var folders: [Folder] = []
    private var membership: [String: UUID] = [:]
    public init() {}
    private func checkedName(_ name: String, excluding: UUID? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw ValidationError.invalidName }
        guard !folders.contains(where: { $0.id != excluding && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw ValidationError.duplicateName }
        return name
    }
    public mutating func createFolder(_ name: String) throws -> UUID {
        let name = try checkedName(name)
        let id = UUID(); folders.append(Folder(id: id, name: name)); return id
    }
    public mutating func renameFolder(_ id: UUID, to name: String) throws {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { throw ValidationError.missingFolder }
        folders[index].name = try checkedName(name, excluding: id)
    }
    public mutating func removeFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        membership = membership.filter { $0.value != id }
    }
    public mutating func move(_ meeting: UUID, to folder: UUID?) throws {
        if let folder, !folders.contains(where: { $0.id == folder }) { throw ValidationError.missingFolder }
        membership[meeting.uuidString] = folder
    }
    public func folder(for meeting: UUID) -> UUID? {
        guard let id = membership[meeting.uuidString], folders.contains(where: { $0.id == id }) else { return nil }
        return id
    }
    public func filtered(_ sessions: [MeetingSession], folder: UUID?, unfiled: Bool, query: String, sort: Sort) -> [MeetingSession] {
        sessions.filter { session in
            (folder == nil || self.folder(for: session.id) == folder) &&
            (!unfiled || self.folder(for: session.id) == nil) &&
            (query.isEmpty || session.title.localizedCaseInsensitiveContains(query))
        }.sorted { lhs, rhs in
            if sort == .title {
                let order = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if order != .orderedSame { return order == .orderedAscending }
            }
            if lhs.created != rhs.created { return sort == .oldest ? lhs.created < rhs.created : lhs.created > rhs.created }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
