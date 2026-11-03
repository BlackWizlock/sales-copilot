import Foundation
import CopilotCore

actor SyntheticBitrix: BitrixTransport {
    var timeoutOnWrite = true
    var omitFiles = false
    var corruptFiles = false
    var renamedFiles = false
    func serverRenamesFiles() { timeoutOnWrite = false; renamedFiles = true }
    func successfulWriteWithWrongFiles() { timeoutOnWrite = false; corruptFiles = true }
    func successfulWrite() { timeoutOnWrite = false }
    func successfulWriteWithoutFiles() { timeoutOnWrite = false; omitFiles = true }
    var missingDisk = false
    var denyFileRead = false
    var hostileDownload = false
    var missingFileID = false
    var legacyDownloads = 0
    func withoutDisk() { timeoutOnWrite = false; missingDisk = true }
    func deniedReadAfterWrite() { timeoutOnWrite = false; denyFileRead = true }
    func malformedFile() { timeoutOnWrite = false; missingFileID = true }
    func hostileFileURL() { timeoutOnWrite = false; hostileDownload = true }
    var writes = 0
    var savedID: String?
    var savedFields: [String: CRMValue] = [:]
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let method = request.url!.lastPathComponent
        if method == "crm_show_file.php" {
            legacyDownloads += 1
            return (Data("<html>Sign in</html>".utf8), 200)
        }
        if method == "download" {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let index = Int(query.first { $0.name == "token" }!.value!)! - 601
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
        if method == "scope.json" {
            return (try JSONEncoder().encode(["result": CRMValue.array((missingDisk ? ["crm"] : ["crm", "disk"]).map(CRMValue.string))]), 200)
        }
        if method == "disk.file.get.json" {
            if denyFileRead { return (Data(#"{"error":"ACCESS_DENIED"}"#.utf8), 403) }
            let id = params["id"]!.text, index = Int(id)! - 601
            let file = savedFields["FILES"]!.array[index].object["fileData"]!.array
            let originalName = file[0].text as NSString
            let returnedName: CRMValue = renamedFiles ? .string(originalName.deletingPathExtension + " (1)." + originalName.pathExtension) : file[0]
            let host = hostileDownload ? "external.invalid" : "axisconsult.bitrix24.ru"
            let result: CRMValue = .object(["ID": .string(id), "TYPE": .string("file"), "NAME": returnedName, "SIZE": .number(Double(Data(base64Encoded: file[1].text)!.count)), "DOWNLOAD_URL": .string("https://\(host)/rest/1/synthetic/download/?token=\(id)")])
            return (try JSONEncoder().encode(["result": result]), 200)
        }
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
            let checkedFiles = missingFileID ? files.map { _ in CRMValue.object(["url": .string("https://axisconsult.bitrix24.ru/bitrix/tools/crm_show_file.php?ownerTypeId=6&ownerId=777")]) } : files
            let rows: [CRMValue] = savedID.map { [.object(["ID": .string($0), "FILES": .array(checkedFiles)])] } ?? []
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
        var noClientSession = try store.create(title: "Missing client preflight")
        noClientSession.state = .completed; noClientSession.transcript = session.transcript
        let noClientContext = DealContext(portal: context.portal, dealID: context.dealID, title: context.title)
        try journal.bind(noClientContext, meetingID: noClientSession.id)
        let preflightTransport = SyntheticBitrix(); await preflightTransport.successfulWrite()
        let preflight = CRMController(store: store, client: BitrixClient(credentials: credentials, transport: preflightTransport), ownerID: "1")
        preflight.activate(session: noClientSession)
        preflight.prepareExport(session: noClientSession, summary: "Synthetic summary", audioURL: nil)
        precondition(preflight.preview == nil, "Missing client must fail before export confirmation")
        let noIntent = try journal.operation(meetingID: noClientSession.id)
        let preflightWrites = await preflightTransport.writes
        precondition(noIntent == nil && preflightWrites == 0, "Local preflight failure must not create an ambiguous journal or send a write")
        await preflight.selectDeal(context.dealID)
        preflight.prepareExport(session: noClientSession, summary: "Synthetic summary", audioURL: nil)
        precondition(preflight.preview != nil, "Refreshing the corrected deal must allow a new preview")
        await preflight.confirmExport(session: noClientSession, summary: "Synthetic summary", audioURL: nil)
        precondition(preflight.exportOperation?.state == .completed)
        print("PASS: missing-client preflight sends no write and allows retry after correcting and refreshing deal")
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
        let legacyDownloads = await audioTransport.legacyDownloads
        precondition(legacyDownloads == 0, "Browser attachment URLs must never be used for machine verification")
        print("PASS: selected-deal export contains exact transcript/audio payload and is completed only after read-back; repeat refused")
        var renamedSession = try store.create(title: "Server duplicate filenames")
        renamedSession.state = .completed; renamedSession.transcript = session.transcript
        try journal.bind(context, meetingID: renamedSession.id)
        let renamedServer = SyntheticBitrix(); await renamedServer.serverRenamesFiles()
        let renamed = CRMController(store: store, client: BitrixClient(credentials: credentials, transport: renamedServer), ownerID: "1")
        renamed.activate(session: renamedSession)
        renamed.prepareExport(session: renamedSession, summary: "Synthetic", audioURL: audioURL)
        await renamed.confirmExport(session: renamedSession, summary: "Synthetic", audioURL: audioURL)
        precondition(renamed.exportOperation?.state == .completed, "Bitrix filename disambiguation must not reject identical attached bytes")
        print("PASS: server-renamed attachments are verified by exact bytes and activity binding")
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
        for mode in ["missingScope", "deniedRead", "hostileURL", "missingFileID"] {
            var probe = try store.create(title: mode)
            probe.state = .completed; probe.transcript = session.transcript
            try journal.bind(context, meetingID: probe.id)
            let server = SyntheticBitrix()
            if mode == "missingScope" { await server.withoutDisk() }
            if mode == "deniedRead" { await server.deniedReadAfterWrite() }
            if mode == "missingFileID" { await server.malformedFile() }
            if mode == "hostileURL" { await server.hostileFileURL() }
            let checker = CRMController(store: store, client: BitrixClient(credentials: credentials, transport: server), ownerID: "1")
            checker.activate(session: probe)
            checker.prepareExport(session: probe, summary: "Synthetic", audioURL: nil)
            await checker.confirmExport(session: probe, summary: "Synthetic", audioURL: nil)
            let count = await server.writes
            if mode == "missingScope" {
                let operation = try journal.operation(meetingID: probe.id)
                precondition(count == 0 && operation == nil, "Missing disk scope must fail before write intent")
                precondition(checker.preview == nil && checker.error != nil, "Preflight error must dismiss the confirmation sheet so its message is visible")
            } else {
                precondition(count == 1 && checker.exportOperation?.state == .needsReconciliation, "Failed read-back after a successful create must block repeat")
                checker.prepareExport(session: probe, summary: "Synthetic", audioURL: nil)
                precondition(checker.preview == nil)
            }
        }
        print("PASS: missing disk scope sends no write; read denial and hostile download preserve reconciliation")
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
