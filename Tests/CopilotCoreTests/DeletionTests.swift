import Foundation
import CopilotCore

final class DeletionTests {
    func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let removed = try store.create(title: "Delete fixture")
        let retained = try store.create(title: "Retain fixture")
        let journal = try CRMJournal(root: root.appendingPathComponent("crm"))
        let context = DealContext(portal: "fixture.bitrix24.ru", dealID: "42", title: "Fixture", fields: [:])
        try journal.bind(context, meetingID: removed.id)
        try Data("private materials".utf8).write(to: store.fileURL(removed.id, filename: "intelligence.json"))
        let access = MCPAccessStore(root: root)
        try access.setEnabled(true); try access.setAllowed(removed.id, allowed: true)
        try access.setAllowed(retained.id, allowed: true)
        try store.deleteMeeting(removed.id)
        expectEqual(FileManager.default.fileExists(atPath: store.directory(removed.id).path), false)
        expectEqual(try journal.context(meetingID: removed.id), nil)
        expectEqual(try access.load().allowedMeetings.contains(removed.id), false)
        expectEqual(try access.load().allowedMeetings.contains(retained.id), true)
        expectEqual(try store.loadAll().map(\.id), [retained.id])
        // A path substituted with a link must not delete the target or grant MCP access.
        let unsafe = UUID()
        try FileManager.default.createSymbolicLink(at: store.directory(unsafe), withDestinationURL: store.directory(retained.id))
        expectThrows(try store.deleteMeeting(unsafe))
        expectEqual(FileManager.default.fileExists(atPath: store.directory(retained.id).appendingPathComponent("session.json").path), true)
        print("PASS: deletion removes local derivatives/CRM snapshots, revokes MCP and preserves other meetings")
    }
}
