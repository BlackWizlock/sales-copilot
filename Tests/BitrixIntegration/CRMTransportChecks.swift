import Foundation
import CopilotCore

actor SyntheticBitrix: BitrixTransport {
    var writes = 0
    var savedID: String?
    var savedFields: [String: CRMValue] = [:]
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let method = request.url!.lastPathComponent
        let params = try JSONDecoder().decode([String: CRMValue].self, from: request.httpBody!)
        let fixtures: [String: CRMValue] = [
            "crm.deal.get.json": .object(["ID": .string("999"), "TITLE": .string("Selected synthetic deal"), "CONTACT_ID": .string("888"), "ASSIGNED_BY_ID": .string("1")]),
            "crm.item.details.configuration.get.json": .array([]),
            "calendar.event.get.json": .array([]),
            "crm.contact.get.json": .object(["NAME": .string("Synthetic contact")])
        ]
        if let result = fixtures[method] { return (try JSONEncoder().encode(["result": result]), 200) }
        if method == "crm.activity.add.json" {
            writes += 1; savedFields = params["fields"]!.object; savedID = "777"
            // The server committed, but the response disappeared. This must never lead to a second create.
            throw URLError(.timedOut)
        }
        if method == "crm.activity.list.json" {
            let rows: [CRMValue] = savedID.map { [.object(["ID": .string($0)])] } ?? []
            return (try JSONEncoder().encode(["result": CRMValue.array(rows)]), 200)
        }
        throw URLError(.unsupportedURL)
    }
}

struct SyntheticFailureBitrix: BitrixTransport {
    let status: Int
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body: [String: CRMValue] = ["error": .string("invalid error https://private.example/secret"), "error_description": .string("sensitive-test-key")]
        return (try JSONEncoder().encode(body), status)
    }
}

@main struct CRMTransportChecks {
    @MainActor static func main() async throws {
        let credentials = try BitrixCredentials(webhook: "https://axisconsult.bitrix24.ru/rest/1/synthetic/")
        let employeeCredentials = try BitrixCredentials(webhook: "https://employee-test.bitrix24.com/rest/2/synthetic/")
        precondition(employeeCredentials.endpoint(method: "user.current").host == "employee-test.bitrix24.com")
        for bad in ["https://axisconsult.bitrix24.ru.evil/rest/1/test/", "http://axisconsult.bitrix24.ru/rest/1/test/", "https://user@axisconsult.bitrix24.ru/rest/1/test/", "https://127.0.0.1/rest/1/test/", "https://192.168.1.1/rest/1/test/"] {
            do { _ = try BitrixCredentials(webhook: bad); preconditionFailure("Accepted invalid portal") } catch { }
        }
        let sanitized = BitrixClient.sanitize(.object(["url": .string("https://axisconsult.bitrix24.ru/rest/1/sensitive/crm.deal.get"), "auth": .string("sensitive"), "file": .string("https://axisconsult.bitrix24.ru/file?auth=sensitive&id=1")])).text
        precondition(!sanitized.contains("sensitive"))
        for status in [200, 302] {
            let failure = BitrixClient(credentials: credentials, transport: SyntheticFailureBitrix(status: status))
            do { _ = try await failure.checkConnection(); preconditionFailure("Expected rejected API response") }
            catch { precondition(!error.localizedDescription.contains("sensitive-test-key") && !error.localizedDescription.contains("private.example")) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = try store.create(title: "Synthetic meeting")
        session.state = .completed
        session.transcript = [TranscriptLine(source: .meeting, start: 0, end: 1, text: "Synthetic agreement")]
        let context = DealContext(portal: "axisconsult.bitrix24.ru", dealID: "999", title: "Synthetic deal", fields: ["CONTACT_ID": .string("888"), "ASSIGNED_BY_ID": .string("1")])
        let journal = try CRMJournal(root: root.appendingPathComponent("crm"))
        try journal.bind(context, meetingID: session.id)
        let transport = SyntheticBitrix()
        let client = BitrixClient(credentials: credentials, transport: transport)
        let controller = CRMController(store: store, client: client, ownerID: "1")
        controller.activate(session: session)
        var unrelated = try store.create(title: "Unbound historical meeting")
        unrelated.state = .completed
        controller.activate(session: unrelated)
        precondition(controller.context == nil)
        let unrelatedBinding = try journal.context(meetingID: unrelated.id)
        precondition(unrelatedBinding == nil)
        controller.activate(session: session)
        let started = try store.create(title: "Explicit new recording")
        controller.activate(session: started, isNew: true)
        let startedBinding = try journal.context(meetingID: started.id)
        precondition(startedBinding?.dealID == context.dealID)
        controller.activate(session: started)
        precondition(controller.context?.dealID == context.dealID)
        controller.activate(session: nil)
        precondition(controller.context == nil)
        controller.activate(session: unrelated)
        precondition(controller.context == nil)
        controller.activate(session: session)
        controller.prepareExport(session: session, summary: "Synthetic summary", audioURL: nil)
        precondition(controller.preview != nil)
        await controller.confirmExport(session: session, summary: "Synthetic summary", audioURL: nil)
        precondition(controller.exportOperation?.state == .needsReconciliation)
        let writes = await transport.writes
        precondition(writes == 1)
        let fields = await transport.savedFields
        precondition(fields["TYPE_ID"] == .number(1) && fields["COMPLETED"] == .string("Y"))
        precondition(fields["OWNER_ID"]?.text == "999" && fields["FILES"]?.array.count == 1)
        precondition(fields["PROVIDER_ID"] == nil && fields["DIRECTION"] == nil)
        // Restart preserves the ambiguous journal; reconciliation finds the committed result.
        let restarted = CRMController(store: store, client: client, ownerID: "1")
        restarted.activate(session: session)
        precondition(restarted.exportOperation?.state == .needsReconciliation)
        await restarted.reconcile(meetingID: session.id)
        precondition(restarted.exportOperation?.state == .completed && restarted.exportOperation?.activityID == "777")
        restarted.prepareExport(session: session, summary: "New summary", audioURL: nil)
        precondition(restarted.preview == nil)
        let finalWrites = await transport.writes
        precondition(finalWrites == 1)
        let selectedMeeting = try store.create(title: "Meeting selected through actual client")
        let selecting = CRMController(store: store, client: client, ownerID: "1")
        selecting.activate(session: selectedMeeting)
        await selecting.selectDeal("999")
        precondition(selecting.context?.title == "Selected synthetic deal")
        let selectedBinding = try journal.context(meetingID: selectedMeeting.id)
        precondition(selectedBinding?.dealID == "999")
        let reopened = CRMController(store: store, client: client, ownerID: "1")
        reopened.activate(session: selectedMeeting)
        precondition(reopened.context?.title == "Selected synthetic deal")
        reopened.activate(session: unrelated)
        precondition(reopened.context == nil)
        print("PASS: synthetic Bitrix auth, redaction, ordinary meeting payload, timeout, restart, reconciliation and duplicate prevention")
    }
}
