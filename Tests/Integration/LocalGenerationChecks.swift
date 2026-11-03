import Foundation
import CopilotCore

/// Intercept only the fixed loopback inference endpoint. No server or model required.
private final class InferenceFixture: URLProtocol {
    nonisolated(unsafe) static var reply = Data()
    nonisolated(unsafe) static var queue: [Data] = []
    nonisolated(unsafe) static var auditIncludesUnquoted = false
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" && request.url?.port == 11434
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; result.append(contentsOf: buffer.prefix(count))
            }
            body = result
        }
        if let body, let value = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let prompt = value["prompt"] as? String, prompt.contains("FACT 0"), prompt.contains("Нецитируемая фраза") {
            Self.auditIncludesUnquoted = true
        }
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
        session.transcript = [TranscriptLine(source: .meeting, start: 0, end: 3, text: "Договорились провести аудит. Нецитируемая фраза о переезде.")]
        let valid = """
        {"facts":[{"kind":"decision","text":"Провести аудит.","owner":"","deadline":"","evidence":[{"segmentID":"\(session.transcript[0].id.uuidString)","quote":"Договорились провести аудит."}]}]}
        """
        let accepted = #"{"verdicts":[{"index":0,"supported":true,"kind":"decision"}]}"#
        let rejected = #"{"verdicts":[{"index":0,"supported":false,"kind":"decision"}]}"#
        func envelope(_ value: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["response":value,"done":true,"done_reason":"stop"])
        }
        InferenceFixture.queue = [try envelope("{"), try envelope(valid), try envelope(accepted)]
        let controller = LocalIntelligence(runtime: runtime)
        controller.observe(session, directory: nil)
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        guard !controller.busySummary, controller.error.isEmpty, controller.record.summary?.citations.count == 1 else {
            throw CopilotError.message("FAIL: malformed summary did not recover with a bounded retry")
        }
        precondition(controller.summaryText.contains("Провести аудит."))
        precondition(!InferenceFixture.auditIncludesUnquoted, "Semantic audit must judge the cited quotation, not unrelated neighbouring sentences")
        print("PASS: malformed summary recovered; validated citations preserved")
        let singleFact = try JSONSerialization.jsonObject(with: Data(valid.utf8)) as! [String: Any]
        let fact = (singleFact["facts"] as! [[String: Any]])[0]
        let twoFacts = String(data: try JSONSerialization.data(withJSONObject: ["facts": [fact, fact]]), encoding: .utf8)!
        InferenceFixture.queue = [try envelope(twoFacts), try envelope(accepted)]
        controller.summarize()
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!controller.error.isEmpty, "Incomplete audit must not silently replace summary with partial coverage")
        // A true quotation elsewhere must not license an unrelated fabricated decision.
        let fabricated = valid.replacingOccurrences(of: "Провести аудит.", with: "Клиент согласовал переезд в дом Артёма.")
        InferenceFixture.queue = [try envelope(fabricated), try envelope(rejected)]
        controller.summarize()
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        guard !controller.summaryText.contains("переезд") else {
            throw CopilotError.message("FAIL: unrelated real citation licensed a fabricated summary claim")
        }
        print("PASS: unsupported claim with unrelated real citation rejected; previous result preserved")
        // A permissive audit cannot override an invented citation or local numerical grounding.
        let wrongQuote = valid.replacingOccurrences(of: "Договорились провести аудит.", with: "Договорились согласовать скидку.")
        InferenceFixture.queue = [try envelope(wrongQuote), try envelope(accepted)]
        controller.summarize()
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!controller.error.isEmpty && controller.summaryText.contains("Провести аудит."))
        InferenceFixture.queue = [try envelope(valid), try envelope(#"{"verdicts":[]}"#)]
        controller.summarize()
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!controller.error.isEmpty && controller.summaryText.contains("Провести аудит."))
        print("PASS: forged evidence and missing audit verdict fail closed")
        // Removing per-fact numeric/identity guards must fail these assertions.
        let invented = valid.replacingOccurrences(of: "Провести аудит.", with: "Провести аудит за 500 рублей.")
        InferenceFixture.queue = [try envelope(invented), try envelope(accepted)]
        controller.summarize()
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!controller.summaryText.contains("500") && !controller.error.isEmpty)
        let action = valid.replacingOccurrences(of: "decision", with: "action").replacingOccurrences(of: "\"owner\":\"\"", with: "\"owner\":\"Иван\"").replacingOccurrences(of: "\"deadline\":\"\"", with: "\"deadline\":\"завтра\"")
        let actionAudit = accepted.replacingOccurrences(of: "decision", with: "action")
        InferenceFixture.queue = [try envelope(action), try envelope(actionAudit)]
        controller.summarize()
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!controller.summaryText.contains("Иван") && !controller.summaryText.contains("завтра"))
        print("PASS: per-fact numerical and explicit owner/deadline guards enforced independently of model audit")
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
