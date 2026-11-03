import Foundation
import CopilotCore

actor DelayedCRMTransport: BitrixTransport {
    let methodToPause: String
    let foundID: String?
    var marker = ""
    private var didPause = false
    func setMarker(_ value: String) { marker = value }
    private var releaseGate: CheckedContinuation<Void, Never>?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(methodToPause: String, foundID: String?) { self.methodToPause = methodToPause; self.foundID = foundID }
    func waitUntilPaused() async {
        if releaseGate != nil { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() { releaseGate?.resume(); releaseGate = nil }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let method = request.url!.lastPathComponent
        if method == methodToPause && !didPause {
            didPause = true
            await withCheckedContinuation { gate in
                releaseGate = gate; waiting.forEach { $0.resume() }; waiting = []
            }
        }
        if method == "scope.json" { return (Data(#"{"result":["crm","disk"]}"#.utf8), 200) }
        if method == "disk.file.get.json" {
            let bytes = Data("[0.0] Звук встречи: Synthetic text".utf8).count
            return (try JSONEncoder().encode(["result": CRMValue.object(["ID": .string("601"), "TYPE": .string("file"), "NAME": .string("transcript.txt"), "SIZE": .number(Double(bytes)), "DOWNLOAD_URL": .string("https://synthetic.bitrix24.ru/rest/1/synthetic/download/?token=test")])]), 200)
        }
        if method == "download" { return (Data("[0.0] Звук встречи: Synthetic text".utf8), 200) }
        if method == "crm.activity.add.json" { throw URLError(.timedOut) }
        if method == "crm.activity.get.json", let foundID {
            let fields: [String: CRMValue] = ["ID": .string(foundID), "OWNER_TYPE_ID": .string("2"), "OWNER_ID": .string("999"), "ORIGINATOR_ID": .string("AXIS_COPILOT"), "ORIGIN_ID": .string(marker), "DESCRIPTION": .string("Summary A\n\nТранскрипция во вложении.\nID экспорта: " + marker), "COMPLETED": .string("Y"), "FILES": .array([.string("601")])]
            return (try JSONEncoder().encode(["result": CRMValue.object(fields)]), 200)
        }
        let rows: [CRMValue] = foundID.map { [.object(["ID": .string($0), "FILES": .array([.object(["id": .string("601"), "url": .string("https://synthetic.bitrix24.ru/bitrix/tools/crm_show_file.php?fileId=601&ownerTypeId=6&ownerId=777&auth=synthetic")])])])] } ?? []
        return (try JSONEncoder().encode(["result": CRMValue.array(rows)]), 200)
    }
}

@main struct CRMIsolationChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        func meeting(_ title: String) throws -> MeetingSession {
            var s = try store.create(title: title); s.state = .completed
            s.transcript = [TranscriptLine(source: .meeting, start: 0, end: 1, text: "Synthetic text")]
            return s
        }
        let a = try meeting("A"), b = try meeting("B")
        let context = DealContext(portal: "synthetic.bitrix24.ru", dealID: "999", title: "A context", fields: ["CONTACT_ID": .string("888")])
        let other = DealContext(portal: "synthetic.bitrix24.ru", dealID: "1000", title: "B context", fields: ["CONTACT_ID": .string("889")])
        let journal = try CRMJournal(root: root.appendingPathComponent("crm"))
        try journal.bind(context, meetingID: a.id); try journal.bind(other, meetingID: b.id)
        let credentials = try BitrixCredentials(webhook: "https://synthetic.bitrix24.ru/rest/1/synthetic/")
        let scopeTransport = DelayedCRMTransport(methodToPause: "scope.json", foundID: nil)
        let scopeController = CRMController(store: store, client: BitrixClient(credentials: credentials, transport: scopeTransport), ownerID: "1")
        scopeController.activate(session: a)
        scopeController.prepareExport(session: a, summary: "Summary A", audioURL: nil)
        let checkingScope = Task { await scopeController.confirmExport(session: a, summary: "Summary A", audioURL: nil) }
        await scopeTransport.waitUntilPaused()
        scopeController.activate(session: b)
        scopeController.prepareExport(session: b, summary: "Summary B", audioURL: nil)
        await scopeTransport.release(); await checkingScope.value
        let staleIntent = try journal.operation(meetingID: a.id)
        precondition(staleIntent == nil && scopeController.preview?.meetingID == b.id && scopeController.error == nil,
                     "Switching meetings during scope preflight must not persist an intent or replace the new preview")
        print("PASS: switching meetings during scope preflight sends no write and preserves the new preview")
        let delayed = DelayedCRMTransport(methodToPause: "crm.activity.add.json", foundID: nil)
        let controller = CRMController(store: store, client: BitrixClient(credentials: credentials, transport: delayed), ownerID: "1")
        controller.activate(session: a)
        controller.prepareExport(session: a, summary: "Summary A", audioURL: nil)
        let sending = Task { await controller.confirmExport(session: a, summary: "Summary A", audioURL: nil) }
        await delayed.waitUntilPaused()
        controller.activate(session: b)
        controller.prepareExport(session: b, summary: "Summary B", audioURL: nil)
        precondition(controller.preview?.meetingID == b.id)
        await delayed.release(); await sending.value
        precondition(controller.preview?.meetingID == b.id && controller.exportOperation == nil && controller.error == nil)
        let persistedA = try journal.operation(meetingID: a.id)
        precondition(persistedA?.state == .needsReconciliation)

        let reconcileTransport = DelayedCRMTransport(methodToPause: "crm.activity.list.json", foundID: "777")
        await reconcileTransport.setMarker("axis-copilot-" + a.id.uuidString.lowercased())
        let reconciling = CRMController(store: store, client: BitrixClient(credentials: credentials, transport: reconcileTransport), ownerID: "1")
        reconciling.activate(session: a)
        let task = Task { await reconciling.reconcile(meetingID: a.id) }
        await reconcileTransport.waitUntilPaused()
        reconciling.activate(session: b)
        reconciling.prepareExport(session: b, summary: "Summary B", audioURL: nil)
        await reconcileTransport.release(); await task.value
        precondition(reconciling.preview?.meetingID == b.id && reconciling.exportOperation == nil && reconciling.error == nil)
        let reconciledA = try journal.operation(meetingID: a.id)
        precondition(reconciledA?.state == .completed && reconciledA?.activityID == "777")
        print("PASS: delayed export/reconciliation preserve original journal without leaking result, error or preview into another meeting")
    }
}
