import Foundation
import CopilotCore

/// Intercept only the fixed loopback inference endpoint. No server or model required.
private final class InferenceFixture: URLProtocol {
    nonisolated(unsafe) static var reply = Data()
    nonisolated(unsafe) static var queue: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && request.url?.port == 11434
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = request.url?.path == "/api/tags" ? Data("{\"models\":[]}".utf8) : (Self.queue.isEmpty ? Self.reply : Self.queue.removeFirst())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct LocalGenerationChecks {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InferenceFixture.self]
        let runtime = IntelligenceRuntime(network: URLSession(configuration: config))
        for body in [
            #"{"response":"{\"overview\":\"cut off","done":true,"done_reason":"length","eval_count":1800}"#,
            #"{"response":"{}","done":false}"#
        ] {
            InferenceFixture.reply = Data(body.utf8)
            do {
                _ = try await runtime.generate(system: "Synthetic", prompt: "Synthetic")
                throw CopilotError.message("FAIL: unfinished model output was accepted")
            } catch let error as CopilotError {
                guard !error.localizedDescription.hasPrefix("FAIL:") else { throw error }
            }
        }
        InferenceFixture.reply = Data(#"{"response":"{\"overview\":\"Complete\"}","done":true,"done_reason":"stop"}"#.utf8)
        let complete = try await runtime.generate(system: "Synthetic", prompt: "Synthetic")
        precondition(complete == #"{"overview":"Complete"}"#)
        print("PASS: unfinished inference rejected; complete structured response preserved")
        var session = MeetingSession(title: "Synthetic")
        session.state = .completed
        session.transcript = [TranscriptLine(source: .meeting, start: 0, end: 3, text: "Договорились провести аудит.")]
        let valid = "{\"overview\":\"Провести аудит.\",\"decisions\":[\"Провести аудит.\"],\"actions\":[],\"questions\":[],\"citations\":[{\"segmentID\":\"\(session.transcript[0].id.uuidString)\",\"quote\":\"Договорились провести аудит.\"}]}"
        func envelope(_ value: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["response":value,"done":true,"done_reason":"stop"])
        }
        InferenceFixture.queue = [try envelope("{"), try envelope(valid)]
        let controller = LocalIntelligence(runtime: runtime)
        controller.observe(session, directory: nil)
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        guard !controller.busySummary, controller.error.isEmpty, controller.record.summary?.citations.count == 1 else {
            throw CopilotError.message("FAIL: malformed summary did not recover with a bounded retry")
        }
        precondition(controller.summaryText.contains("Провести аудит."))
        print("PASS: malformed summary recovered; validated citations preserved")
        let previous = controller.summaryText
        InferenceFixture.queue = [try envelope("{"), try envelope("{")]
        controller.summarize()
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!controller.busySummary && !controller.error.isEmpty && controller.summaryText == previous)
        precondition(InferenceFixture.queue.isEmpty)
        print("PASS: repeated format failure stops after one retry and preserves previous summary")
        InferenceFixture.queue = [try envelope(valid)]
        controller.summarize(); controller.cancelSummary()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(!controller.busySummary && controller.summaryStartedAt == nil && controller.summaryText == previous)
        precondition(InferenceFixture.queue.count == 1)
        print("PASS: cancellation clears progress without starting inference or replacing saved summary")
    }
}
