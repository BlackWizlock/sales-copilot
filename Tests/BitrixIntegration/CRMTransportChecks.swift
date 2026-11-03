import Foundation
import CopilotCore

actor SyntheticBitrix: BitrixTransport {
    var timeoutOnWrite = true
    var omitFiles = false
    var corruptFiles = false
    func successfulWriteWithWrongFiles() { timeoutOnWrite = false; corruptFiles = true }
    func successfulWrite() { timeoutOnWrite = false }
    func successfulWriteWithoutFiles() { timeoutOnWrite = false; omitFiles = true }
    var writes = 0
    var savedID: String?
    var savedFields: [String: CRMValue] = [:]
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let method = request.url!.lastPathComponent
        if method == "crm_show_file.php" {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let index = Int(query.first { $0.name == "fileId" }!.value!)! - 601
            let encoded = savedFields["FILES"]!.array[index].object["fileData"]!.array[1].text
            return (corruptFiles ? Data("Wrong attachment".utf8) : Data(base64Encoded: encoded)!, 200)
        }
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
            if timeoutOnWrite { throw URLError(.timedOut) }
            return (try JSONEncoder().encode(["result": CRMValue.string("777")]), 200)
        }
        if method == "crm.activity.get.json" {
            var fields = savedFields
            fields["ID"] = .string("777")
            fields["FILES"] = .array(omitFiles ? [] : (savedFields["FILES"]?.array ?? []).enumerated().map { .string(String(601 + $0.offset)) })
            return (try JSONEncoder().encode(["result": CRMValue.object(fields)]), 200)
        }
        if method == "crm.activity.list.json" {
            let files = omitFiles ? [] : (savedFields["FILES"]?.array ?? []).enumerated().map { index, _ in
                CRMValue.object(["id": .string(String(601 + index)), "url": .string("https://axisconsult.bitrix24.ru/bitrix/tools/crm_show_file.php?fileId=\(601 + index)&ownerTypeId=6&ownerId=777&auth=synthetic")])
            }
            let rows: [CRMValue] = savedID.map { [.object(["ID": .string($0), "FILES": .array(files)])] } ?? []
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
        var audioSession = try store.create(title: "Audio workflow")
        audioSession.state = .completed; audioSession.transcript = session.transcript
        try journal.bind(context, meetingID: audioSession.id)
        let audioURL = root.appendingPathComponent("synthetic.m4a")
        let audioBytes = Data([0, 0, 0, 24, 102, 116, 121, 112, 77, 52, 65, 32])
        try audioBytes.write(to: audioURL)
        let audioTransport = SyntheticBitrix(); await audioTransport.successfulWrite()
        let audioController = CRMController(store: store, client: BitrixClient(credentials: credentials, transport: audioTransport), ownerID: "1")
        audioController.activate(session: audioSession)
        audioController.prepareExport(session: audioSession, summary: "Reviewed synthetic result", audioURL: audioURL)
        await audioController.confirmExport(session: audioSession, summary: "Reviewed synthetic result", audioURL: audioURL)
        precondition(audioController.exportOperation?.state == .completed)
        let audioFields = await audioTransport.savedFields
        let attachments = audioFields["FILES"]?.array ?? []
        precondition(attachments.count == 2)
        precondition(attachments[0].object["fileData"]?.array.first?.text == "transcript.txt")
        precondition(attachments[1].object["fileData"]?.array.first?.text == "synthetic.m4a")
        precondition(Data(base64Encoded: attachments[1].object["fileData"]!.array[1].text) == audioBytes)
        audioController.prepareExport(session: audioSession, summary: "Reviewed synthetic result", audioURL: audioURL)
        precondition(audioController.preview == nil)
        print("PASS: selected-deal export contains exact transcript/audio payload and is completed only after read-back; repeat refused")
        // An API ID alone does not prove attached transcript/audio were saved.
        var missingFilesSession = try store.create(title: "Missing server attachments")
        missingFilesSession.state = .completed
        missingFilesSession.transcript = session.transcript
        try journal.bind(context, meetingID: missingFilesSession.id)
        let missingFilesTransport = SyntheticBitrix()
        await missingFilesTransport.successfulWriteWithoutFiles()
        let missingFiles = CRMController(store: store, client: BitrixClient(credentials: credentials, transport: missingFilesTransport), ownerID: "1")
        missingFiles.activate(session: missingFilesSession)
        missingFiles.prepareExport(session: missingFilesSession, summary: "Synthetic summary", audioURL: nil)
        await missingFiles.confirmExport(session: missingFilesSession, summary: "Synthetic summary", audioURL: nil)
        guard missingFiles.exportOperation?.state == .needsReconciliation else {
            throw CopilotError.message("FAIL: successful activity ID without attachments was reported completed")
        }
        print("PASS: remote incomplete attachment result is held for reconciliation")
        var replaced = try store.create(title: "Wrong server attachments")
        replaced.state = .completed; replaced.transcript = session.transcript
        try journal.bind(context, meetingID: replaced.id)
        let wrongTransport = SyntheticBitrix(); await wrongTransport.successfulWriteWithWrongFiles()
        let wrong = CRMController(store: store, client: BitrixClient(credentials: credentials, transport: wrongTransport), ownerID: "1")
        wrong.activate(session: replaced)
        wrong.prepareExport(session: replaced, summary: "Synthetic summary", audioURL: nil)
        await wrong.confirmExport(session: replaced, summary: "Synthetic summary", audioURL: nil)
        precondition(wrong.exportOperation?.state == .needsReconciliation, "Unrelated same-count attachments must not confirm export")
        print("PASS: replaced same-count attachment is rejected")
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
