import Foundation
import CopilotCore

final class MCPTests {
    func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func check(_ value: @autoclosure () throws -> Bool) throws { let result = try value(); precondition(result) }
        let store = try SessionStore(root: root)
        var permitted = try store.create(title: "Permitted")
        permitted.transcript = [TranscriptLine(source: .meeting, start: 2, end: 4, text: "Agreement for synthetic test")]
        try store.save(permitted)
        let denied = try store.create(title: "Secret denied meeting")
        let policy = MCPAccessStore(root: root)
        let archive = MCPArchive(root: root)
        let before = try archive.list(offset: 0, limit: 20)
        precondition(before.items.isEmpty)
        try policy.setEnabled(true)
        try policy.setAllowed(permitted.id, allowed: true)
        let listed = try archive.list(offset: 0, limit: 20)
        precondition(listed.items.count == 1 && listed.items[0].id == permitted.id)
        let live = try archive.session(permitted.id)
        precondition(live.state == .recording) // Reading must not reinterpret active recording as interrupted.
        let lines = try archive.transcript(permitted.id, offset: 0, limit: 20)
        precondition(lines.items.count == 1 && lines.items[0].start == 2)
        let found = try archive.search("agreement", offset: 0, limit: 20)
        precondition(found.items.count == 1)
        func unavailable(_ id: UUID) -> String {
            do { _ = try archive.session(id); return "LEAK" } catch { return error.localizedDescription }
        }
        precondition(unavailable(denied.id) == unavailable(UUID()))
        // Exact inclusive dates, snapshot-only deal filtering and deterministic equal-date pages.
        let timestamp = Date(timeIntervalSince1970: 1_735_689_600)
        permitted.created = timestamp; try store.save(permitted)
        var peer = try store.create(title: "Agreement peer"); peer.created = timestamp; try store.save(peer)
        try policy.setAllowed(peer.id, allowed: true)
        let crm = root.appendingPathComponent("crm", isDirectory: true)
        try FileManager.default.createDirectory(at: crm, withIntermediateDirectories: true)
        let snapshot = DealContext(portal: "synthetic.bitrix24.ru", dealID: "123", title: "Private snapshot")
        let snapshotURL = crm.appendingPathComponent("\(permitted.id.uuidString)-deal.json")
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        let exact = try MCPMeetingFilter(from: "2025-01-01T00:00:00Z", to: "2025-01-01T03:00:00+03:00", dealID: "123")
        let filtered = try archive.list(offset: 0, limit: 1, filter: exact)
        precondition(filtered.items.map(\.id) == [permitted.id] && filtered.nextOffset == nil)
        try check(archive.search("agreement", offset: 0, limit: 20, filter: exact).items.count == 1)
        let missing = try MCPMeetingFilter(dealID: "124")
        try check(archive.list(offset: 0, limit: 20, filter: missing).items.isEmpty)
        let ordered = [permitted.id, peer.id].sorted { $0.uuidString < $1.uuidString }
        for offset in 0...1 {
            let page = try archive.list(offset: offset, limit: 1)
            precondition(page.items.map(\.id) == [ordered[offset]])
            precondition(page.nextOffset == (offset == 0 ? 1 : nil))
        }
        for values in [("invalid", "", ""), ("2025-01-02T00:00:00Z", "2025-01-01T00:00:00Z", ""), ("", "", "0"), ("", "", "../123"), ("", "", "9223372036854775808"), ("2025-01-01", "", ""), ("2025-02-30T00:00:00Z", "", ""), ("2025-01-01T24:00:00Z", "", ""), ("2025-01-01T00:00:00+24:00", "", "")] {
            do {
                _ = try MCPMeetingFilter(from: values.0.isEmpty ? nil : values.0, to: values.1.isEmpty ? nil : values.1, dealID: values.2.isEmpty ? nil : values.2)
                preconditionFailure("Invalid filter accepted")
            } catch { precondition(error is MCPArchiveError) }
        }
        try FileManager.default.removeItem(at: snapshotURL)
        try FileManager.default.createSymbolicLink(at: snapshotURL, withDestinationURL: try store.fileURL(denied.id, filename: "session.json"))
        try check(archive.list(offset: 0, limit: 20, filter: exact).items.isEmpty)
        try policy.setAllowed(peer.id, allowed: false)
        // Journal is bounded, private, omits denied IDs, and refuses links/hard links.
        let audit = MCPAuditStore(root: root), auditURL = root.appendingPathComponent("mcp-audit.jsonl")
        for _ in 0..<600 { try audit.record(tool: "meeting_get", meetingID: permitted.id, outcome: "success", count: 1) }
        try audit.record(tool: "meeting_get", meetingID: denied.id, outcome: "denied", count: 0)
        let auditData = try Data(contentsOf: auditURL)
        precondition(auditData.count <= MCPAuditStore.maximumBytes)
        precondition(!String(decoding: auditData, as: UTF8.self).contains(denied.id.uuidString))
        let rows = String(decoding: auditData, as: UTF8.self).split(separator: "\n")
        precondition(rows.count < 601)
        for row in rows {
            let entry = try JSONSerialization.jsonObject(with: Data(row.utf8)) as! [String: Any]
            precondition(Set(entry.keys).isSubset(of: ["timestamp", "tool", "meetingID", "outcome", "count"]))
        }
        let mode = try FileManager.default.attributesOfItem(atPath: auditURL.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600)
        try FileManager.default.removeItem(at: auditURL)
        let target = root.appendingPathComponent("untouched.txt")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: auditURL, withDestinationURL: target)
        do { try audit.record(tool: "meeting_get", outcome: "denied", count: 0); preconditionFailure("Audit link accepted") } catch {}
        try check(Data(contentsOf: target) == Data("untouched".utf8))
        try FileManager.default.removeItem(at: auditURL)
        try FileManager.default.linkItem(at: target, to: auditURL)
        do { try audit.record(tool: "meeting_get", outcome: "denied", count: 0); preconditionFailure("Audit hard link accepted") } catch {}
        try FileManager.default.removeItem(at: auditURL)
        try policy.setAllowed(permitted.id, allowed: false)
        precondition(unavailable(permitted.id) == unavailable(denied.id))
        try policy.setAllowed(permitted.id, allowed: true)
        let manifest = try store.fileURL(permitted.id, filename: "session.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: try store.fileURL(denied.id, filename: "session.json"))
        precondition(unavailable(permitted.id) == unavailable(denied.id))
        try policy.setEnabled(false)
        let disabled = try archive.list(offset: 0, limit: 20)
        precondition(disabled.items.isEmpty)
        print("PASS: MCP explicit access, date/deal filters, deterministic pages, bounded private audit, fresh revocation and link denial")
    }
}
#if MCP_STANDALONE
@main struct MCPMain { static func main() throws { try MCPTests().run() } }
#endif

#if MCP_PROTOCOL_STANDALONE
@main struct MCPProtocolChecks {
    static func main() throws {
        if CommandLine.arguments.contains("--serve"), let raw = CommandLine.arguments.last {
            MCPServer.run(root: URL(fileURLWithPath: raw, isDirectory: true)); return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = try store.create(title: "Protocol fixture")
        session.transcript = [TranscriptLine(source: .meeting, start: 3, end: 5, text: "Protocol agreement")]
        try store.save(session)
        let policy = MCPAccessStore(root: root)
        try policy.setEnabled(true); try policy.setAllowed(session.id, allowed: true)
        let crm = root.appendingPathComponent("crm", isDirectory: true)
        try FileManager.default.createDirectory(at: crm, withIntermediateDirectories: true)
        try JSONEncoder().encode(DealContext(portal: "synthetic.bitrix24.ru", dealID: "123", title: "Private CRM title"))
            .write(to: crm.appendingPathComponent("\(session.id.uuidString)-deal.json"))
        // Exercise the actual blocking stdio loop in a separate process, not only its handler.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--serve", root.path]
        let input = Pipe(), output = Pipe()
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.standardError
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        func exchange(_ request: [String: Any]) throws -> [String: Any] {
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(10); try input.fileHandleForWriting.write(contentsOf: data)
            var response = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                if byte[0] == 10 { break }
                response.append(byte)
                precondition(response.count <= 65_536)
            }
            return try JSONSerialization.jsonObject(with: response) as! [String: Any]
        }
        let handshake = try exchange(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "stdio-check", "version": "1"]]])
        precondition(handshake["result"] != nil)
        var notice = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        notice.append(10); try input.fileHandleForWriting.write(contentsOf: notice)
        let listed = try exchange(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        precondition(((listed["result"] as? [String: Any])?["tools"] as? [Any])?.count == 6)
        let read = try exchange(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "meeting_transcript", "arguments": ["meetingID": session.id.uuidString]]])
        let readText = (((read["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        precondition(readText.contains("Protocol agreement") && readText.contains("\"start\":3"))
        let filtered = try exchange(["jsonrpc": "2.0", "id": 31, "method": "tools/call", "params": ["name": "meeting_list", "arguments": ["from": "2099-01-01T00:00:00Z", "dealID": "999"]]])
        let filteredText = (((filtered["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        precondition(filteredText.contains("\"items\":[]"))
        let positive = try exchange(["jsonrpc": "2.0", "id": 34, "method": "tools/call", "params": ["name": "meeting_search", "arguments": ["query": "agreement", "from": "2020-01-01T00:00:00.000Z", "to": "2099-01-01T00:00:00Z", "dealID": "123"]]])
        let positiveText = (((positive["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        precondition(positiveText.contains(session.id.uuidString) && positiveText.contains("Protocol agreement"))
        for args: [String: Any] in [["from": "yesterday"], ["dealID": 123], ["to": true], ["dealID": "-1"], ["from": "2026-01-01T00:00:00Z", "to": "2025-01-01T00:00:00Z"]] {
            let invalid = try exchange(["jsonrpc": "2.0", "id": 32, "method": "tools/call", "params": ["name": "meeting_list", "arguments": args]])
            precondition((invalid["result"] as? [String: Any])?["isError"] as? Bool == true)
        }
        try policy.setAllowed(session.id, allowed: false)
        let denied = try exchange(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "meeting_get", "arguments": ["meetingID": session.id.uuidString]]])
        precondition((denied["result"] as? [String: Any])?["isError"] as? Bool == true)
        let auditURL = root.appendingPathComponent("mcp-audit.jsonl")
        let auditText = try String(contentsOf: auditURL, encoding: .utf8)
        precondition(auditText.contains(session.id.uuidString) && !auditText.contains("Protocol agreement") && !auditText.contains("yesterday") && !auditText.contains("999"))
        let lastEntry = try JSONSerialization.jsonObject(with: Data(auditText.split(separator: "\n").last!.utf8)) as! [String: Any]
        precondition(lastEntry["meetingID"] == nil && lastEntry["outcome"] as? String == "denied")
        // A journal link prevents disclosure even for a permitted record.
        try policy.setAllowed(session.id, allowed: true)
        try FileManager.default.removeItem(at: auditURL)
        let target = root.appendingPathComponent("protected-audit-target")
        try Data("sentinel".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: auditURL, withDestinationURL: target)
        let blocked = try exchange(["jsonrpc": "2.0", "id": 33, "method": "tools/call", "params": ["name": "meeting_transcript", "arguments": ["meetingID": session.id.uuidString]]])
        precondition((blocked["result"] as? [String: Any])?["isError"] as? Bool == true)
        precondition(!String(describing: blocked).contains("Protocol agreement"))
        try FileManager.default.removeItem(at: auditURL)
        try input.fileHandleForWriting.close()
        child.waitUntilExit(); precondition(child.terminationStatus == 0)
        try policy.setAllowed(session.id, allowed: true)
        print("PASS: real MCP stdio handshake, six tools, date/deal search, audit fail-closed, active-client revocation and clean EOF")
        let endpoint = MCPProtocol(root: root)
        func call(_ value: [String: Any]) throws -> [String: Any]? {
            guard let data = endpoint.process(try JSONSerialization.data(withJSONObject: value)) else { return nil }
            precondition(data.count <= 65536)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let premature = try call(["jsonrpc": "2.0", "id": 0, "method": "tools/list"])
        precondition((premature?["error"] as? [String: Any])?["code"] as? Int == -32002)
        let initialized = try call(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "synthetic", "version": "1"]]])
        precondition((initialized?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
        let notification = try call(["jsonrpc": "2.0", "method": "notifications/initialized"])
        precondition(notification == nil)
        let tools = try call(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        precondition(((tools?["result"] as? [String: Any])?["tools"] as? [Any])?.count == 6)
        let transcript = try call(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "meeting_transcript", "arguments": ["meetingID": session.id.uuidString]]])
        let text = (((transcript?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        precondition(text.contains("Protocol agreement") && text.contains("\"start\":3"))
        let badPath = try call(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "meeting_get", "arguments": ["meetingID": session.id.uuidString, "path": "../session.json"]]])
        precondition((badPath?["result"] as? [String: Any])?["isError"] as? Bool == true)
        try policy.setAllowed(session.id, allowed: false)
        let revoked = try call(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "meeting_get", "arguments": ["meetingID": session.id.uuidString]]])
        precondition((revoked?["result"] as? [String: Any])?["isError"] as? Bool == true)
        let oversized = endpoint.process(Data(repeating: 32, count: 65537))!
        precondition(oversized.count < 65536)
        print("PASS: full MCP JSON-RPC initialize, notification, tools/list, tools/call, timestamps, path denial, revocation and frame limit")
    }
}
#endif
