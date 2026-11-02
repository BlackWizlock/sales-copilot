import Foundation
import CopilotCore

actor LaunchTransport: BitrixTransport {
    var releaseGate: CheckedContinuation<Void, Never>?
    var waiting: CheckedContinuation<Void, Never>?
    func paused() async {
        if releaseGate != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { releaseGate?.resume(); releaseGate = nil }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let method = request.url!.lastPathComponent
        let result: CRMValue
        switch method {
        case "crm.deal.get.json": result = .object(["ID": .string("42"), "TITLE": .string("Synthetic deal")])
        case "crm.item.details.configuration.get.json": result = .object([:])
        case "crm.activity.list.json": result = .array([])
        case "calendar.event.get.json":
            // Last await in loadDeal: deliberately ignore cancellation to exercise
            // the controller's commit guard rather than URLSession cancellation.
            await withCheckedContinuation { releaseGate = $0; waiting?.resume(); waiting = nil }
            result = .array([])
        default: fatalError("Unexpected method (writes are forbidden in launch tests)")
        }
        return (try JSONEncoder().encode(["result": result]), 200)
    }
}

@main struct DealLaunchChecks {
    @MainActor static func main() async throws {
        let base = "axis-copilot://deal?portal=synthetic.bitrix24.ru&id=42"
        let request = try DealLaunchRequest(base)
        precondition(request.portal == "synthetic.bitrix24.ru" && request.dealID == "42")
        precondition(request.dealURL.absoluteString == "https://synthetic.bitrix24.ru/crm/deal/details/42/")
        let reordered = try DealLaunchRequest("axis-copilot://deal?id=00042&portal=synthetic.bitrix24.ru")
        precondition(reordered == request)
        let bad = [base + "&auth=secret", base + "&id=43", base + "&portal=other.bitrix24.ru", base + "#fragment",
            base + "#", base + "\n", base + "&", base.replacingOccurrences(of: "42", with: "0"),
            base.replacingOccurrences(of: "42", with: "-42"), base.replacingOccurrences(of: "42", with: "+42"),
            base.replacingOccurrences(of: "42", with: "4.2"), base.replacingOccurrences(of: "42", with: "%34%32"),
            base.replacingOccurrences(of: "42", with: "４２"), base.replacingOccurrences(of: "42", with: String(repeating: "9", count: 600)),
            base.replacingOccurrences(of: "synthetic.bitrix24.ru", with: "localhost"),
            base.replacingOccurrences(of: "synthetic.bitrix24.ru", with: "synthetic.bitrix24.ru.evil.example"),
            base.replacingOccurrences(of: "synthetic.bitrix24.ru", with: "https://synthetic.bitrix24.ru/rest/1/secret/"),
            base.replacingOccurrences(of: "portal=", with: "%70ortal="),
            base.replacingOccurrences(of: "//deal?", with: "//user:secret@deal?"),
            base.replacingOccurrences(of: "//deal?", with: "//deal:443?"),
            base.replacingOccurrences(of: "//deal?", with: "//deal/?"),
            base.replacingOccurrences(of: "//deal?", with: "//deal/start?"),
            base.replacingOccurrences(of: "axis-copilot", with: "https"),
            "axis-copilot://deal?portal=synthetic.bitrix24.ru", "axis-copilot://deal?id=42"]
        for raw in bad {
            do { _ = try DealLaunchRequest(raw); fatalError("Unsafe link accepted") }
            catch { precondition(!error.localizedDescription.contains("secret")) }
        }
        let gate = DealLaunchPreparation()
        var state = DealLaunchState(portal: request.portal, busy: false, revision: 0)
        var reads = 0, confirmations = 0, applies = 0
        let preview = DealLaunchPreview(title: "Real synthetic title", client: "Synthetic client")
        func run(accept: Bool = true, mutateRead: Bool = false, mutateConfirm: Bool = false) async throws -> DealLaunchPreparation.Result {
            try await gate.prepare(request, state: { state }, read: { received in
                precondition(received == request); reads += 1
                if mutateRead { state.revision += 1 }
                await Task.yield()
                return preview
            }, confirm: { shown in
                precondition(shown == preview); confirmations += 1
                if mutateConfirm { state.revision += 1 }
                return accept
            }, apply: { applies += 1 })
        }
        let cancelled = try await run(accept: false)
        precondition(cancelled == .cancelled && applies == 0 && reads == 1 && confirmations == 1)
        state.portal = "other.bitrix24.ru"
        do { _ = try await run(); fatalError("Portal mismatch accepted") } catch {}
        state.portal = nil
        do { _ = try await run(); fatalError("Disconnected launch accepted") } catch {}
        state.portal = request.portal; state.busy = true
        do { _ = try await run(); fatalError("Busy launch accepted") } catch {}
        precondition(reads == 1 && confirmations == 1 && applies == 0)
        state.busy = false
        let staleRead = try await run(mutateRead: true)
        let staleConfirm = try await run(mutateConfirm: true)
        precondition(staleRead == .stale && staleConfirm == .stale && applies == 0 && confirmations == 2)
        // A connection/busy transition that has already returned to the old value
        // is still rejected by its revision, not only its final boolean/host.
        let transient = try await gate.prepare(request, state: { state }, read: { _ in
            state.busy = true; state.revision += 1; state.busy = false
            return preview
        }, confirm: { _ in fatalError("Stale preview confirmed") }, apply: { applies += 1 })
        precondition(transient == .stale && applies == 0)
        let prepared = try await run()
        precondition(prepared == .prepared && applies == 1 && !gate.running)
        do {
            _ = try await gate.prepare(request, state: { state }, read: { _ in throw URLError(.timedOut) }, confirm: { _ in fatalError() }, apply: { fatalError() })
            fatalError("Failed read accepted")
        } catch { precondition(!gate.running && applies == 1) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let transport = LaunchTransport()
        let credentials = try BitrixCredentials(webhook: "https://synthetic.bitrix24.ru/rest/1/synthetic/")
        let controller = CRMController(store: store, client: BitrixClient(credentials: credentials, transport: transport), ownerID: "1")
        // No actual Keychain, live portal, microphone, recording or CRM writes.
        do { _ = try await controller.previewDealForLaunch(request); fatalError("Unverified portal accepted") } catch {}
        let loading = Task { await controller.selectDeal("42") }
        await transport.paused()
        loading.cancel()
        await transport.release(); await loading.value
        precondition(controller.context == nil && !controller.busy)
        let historical = try store.create(title: "Synthetic history")
        let journal = try CRMJournal(root: root.appendingPathComponent("crm"))
        let original = DealContext(portal: request.portal, dealID: "99", title: "Historical binding")
        try journal.bind(original, meetingID: historical.id)
        controller.activate(session: historical)
        // Mirrors newMeeting's current=nil activation, before choosing a new deal.
        controller.activate(session: nil)
        var mayCommit = true
        let obsolete = Task { await controller.selectDeal("42", allowingCommit: { mayCommit }) }
        await transport.paused()
        mayCommit = false
        await transport.release(); await obsolete.value
        let saved = try journal.context(meetingID: historical.id)
        precondition(controller.context == nil && !controller.busy && saved == original)
        print("PASS: strict deal links; consent/cancel, portal, busy, transient/stale state, read failure; cancelled CRM response cannot bind context; no external services")
    }
}
