import Foundation
import CopilotCore

final class GUIInstanceTests {
    func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var first = try GUIInstanceLease.acquire(directory: root)
        precondition(first != nil)
        let duplicate = try GUIInstanceLease.acquire(directory: root)
        precondition(duplicate == nil, "A second GUI must not acquire the same recording data")
        first = nil
        let restarted = try GUIInstanceLease.acquire(directory: root)
        precondition(restarted != nil, "A terminated GUI must release the lease")
        withExtendedLifetime(restarted) {}
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root)
        do { _ = try GUIInstanceLease.acquire(directory: linked); preconditionFailure("Symlink root accepted") } catch {}
        print("PASS: GUI exclusive lease, release/restart and symlink rejection")
    }
}
