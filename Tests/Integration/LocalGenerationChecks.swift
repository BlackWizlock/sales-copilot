import Foundation
import CopilotCore

/// Intercept only the fixed loopback inference endpoint. No server or model required.
private final class InferenceFixture: URLProtocol {
    nonisolated(unsafe) static var reply = Data()
    nonisolated(unsafe) static var queue: [Data] = []
    nonisolated(unsafe) static var oversizedExtraction = false
    nonisolated(unsafe) static var largestAuditPrompt = 0
    nonisolated(unsafe) static var auditPrompts: [String] = []
    nonisolated(unsafe) static var holdSecondAudit = false
    nonisolated(unsafe) static var secondAuditHeld = false
    private var withheld = false
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
           let prompt = value["prompt"] as? String {
            if prompt.contains("ORIGINAL SOURCES:") { Self.largestAuditPrompt = max(Self.largestAuditPrompt, prompt.count); Self.auditPrompts.append(prompt) }
            if Self.holdSecondAudit && prompt.hasPrefix("FACT 1\n") {
                Self.secondAuditHeld = true; withheld = true; return
            }
            if !prompt.contains("FACT 0"), let format = value["format"] as? [String: Any],
               let properties = format["properties"] as? [String: Any], let facts = properties["facts"] as? [String: Any],
               let maximum = facts["maxItems"] as? Int, maximum > 6 { Self.oversizedExtraction = true }
        }
        let data = request.url?.path == "/api/tags" ? Data("{\"models\":[]}".utf8) : (Self.queue.isEmpty ? Self.reply : Self.queue.removeFirst())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { if withheld { Self.secondAuditHeld = false } }
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
        let valid = """
        {"facts":[{"kind":"decision","text":"Провести аудит.","owner":"","deadline":"","sourceIDs":[0]}]}
        """
        let indexed = try JSONDecoder().decode(GroundedMeetingNotes.IndexedDraft.self, from: Data(valid.utf8))
        let resolved = indexed.grounded(in: session.transcript)
        precondition(resolved.facts[0].evidence[0].quote == session.transcript[0].text)
        precondition(resolved.facts[0].evidence[0].segmentID == session.transcript[0].id)
        precondition(indexed.grounded(in: session.transcript, allowedSourceIDs: []).facts[0].evidence.isEmpty,
                     "A source outside the current batch cannot support a fact")
        let accepted = #"{"verdicts":{"0":{"supported":true,"meaningful":true,"kind":"decision"}}}"#
        let shortLines = [TranscriptLine(source: .meeting, start: 0, end: 1, text: "Предлагаю провести аудит."),
                          TranscriptLine(source: .microphone, start: 1, end: 2, text: "Да.")]
        let shortDraft = valid.replacingOccurrences(of: "[0]", with: "[0,1]")
        let shortResolved = try JSONDecoder().decode(GroundedMeetingNotes.IndexedDraft.self, from: Data(shortDraft.utf8)).grounded(in: shortLines)
        let shortAudit = try JSONDecoder().decode(GroundedMeetingNotes.Audit.self, from: Data(#"{"verdicts":[{"index":0,"supported":true,"meaningful":true,"kind":"decision"}]}"#.utf8))
        precondition(shortResolved.validated(in: shortLines, audit: shortAudit).facts.count == 1,
                     "An exact short acceptance must not erase an explicit agreement")
        let rejected = #"{"verdicts":{"0":{"supported":false,"meaningful":true,"kind":"decision"}}}"#
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
        precondition(!InferenceFixture.oversizedExtraction, "Summary extraction must bound output to six concise facts per batch")
        print("PASS: malformed summary recovered; validated citations preserved")
        let singleFact = try JSONSerialization.jsonObject(with: Data(valid.utf8)) as! [String: Any]
        let fact = (singleFact["facts"] as! [[String: Any]])[0]
        let twoFacts = String(data: try JSONSerialization.data(withJSONObject: ["facts": [fact, fact]]), encoding: .utf8)!
        InferenceFixture.queue = [try envelope(twoFacts), try envelope(accepted)]
        controller.summarize()
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!controller.error.isEmpty && controller.summaryText.contains("Провести аудит."), "A late incomplete audit must preserve the previous summary rather than publish a partial result")
        // A true quotation elsewhere must not license an unrelated fabricated decision.
        let fabricated = valid.replacingOccurrences(of: "Провести аудит.", with: "Клиент согласовал переезд в дом Артёма.")
        InferenceFixture.queue = [try envelope(fabricated), try envelope(rejected)]
        controller.summarize()
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        guard !controller.summaryText.contains("переезд") else {
            throw CopilotError.message("FAIL: unrelated real citation licensed a fabricated summary claim")
        }
        print("PASS: unsupported claim with unrelated real citation rejected; previous result preserved")
        var incoherent = session
        incoherent.id = UUID()
        incoherent.transcript = [TranscriptLine(source: .meeting, start: 0, end: 3, text: "Обсуждаем стоимость протеин.")]
        let incoherentFact = valid.replacingOccurrences(of: "decision", with: "topic")
            .replacingOccurrences(of: "Провести аудит.", with: "Обсудили стоимость протеин.")
        InferenceFixture.queue = [try envelope(incoherentFact), try envelope(#"{"verdicts":{"0":{"supported":true,"meaningful":false,"kind":"topic"}}}"#)]
        controller.observe(incoherent, directory: nil)
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!controller.error.isEmpty && !controller.summaryText.contains("протеин"),
                     "A literally quoted but incoherent recognition fragment must not become a meaningful summary topic")
        InferenceFixture.queue = [try envelope(valid), try envelope(accepted)]
        controller.observe(session, directory: nil)
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(controller.error.isEmpty && controller.summaryText.contains("Провести аудит."))
        print("PASS: incoherent but literally supported speech is omitted without inventing a correction")
        // A permissive audit cannot override an invented citation or local numerical grounding.
        let wrongIndex = valid.replacingOccurrences(of: #""sourceIDs":[0]"#, with: #""sourceIDs":[9999]"#)
        InferenceFixture.queue = [try envelope(wrongIndex), try envelope(accepted)]
        controller.summarize()
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!controller.error.isEmpty && controller.summaryText.contains("Провести аудит."))
        InferenceFixture.queue = [try envelope(valid), try envelope(#"{"verdicts":{}}"#)]
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
        for ids in ["[-1]", "[0,0]"] {
            InferenceFixture.queue = [try envelope(valid.replacingOccurrences(of: "[0]", with: ids)), try envelope(accepted)]
            controller.summarize()
            for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(!controller.error.isEmpty)
        }
        var discussion = session
        discussion.id = UUID()
        discussion.transcript = [TranscriptLine(source: .meeting, start: 0, end: 3, text: "Надо посмотреть материалы. В прошлый раз решили пойти через знакомого.")]
        let falseAction = valid.replacingOccurrences(of: "decision", with: "action")
            .replacingOccurrences(of: "Провести аудит.", with: "Посмотреть материалы.")
        InferenceFixture.queue = [try envelope(falseAction), try envelope(actionAudit)]
        controller.observe(discussion, directory: nil)
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!controller.error.isEmpty, "A discussion cannot become an assigned task even with a permissive audit")
        var multi = MeetingSession(title: "Synthetic two batches")
        multi.state = .completed
        multi.transcript = [TranscriptLine(source: .meeting, start: 0, end: 3, text: "Договорились провести аудит. " + String(repeating: "тема ", count: 790)),
                            TranscriptLine(source: .meeting, start: 4, end: 6, text: "Обсудили обучение сотрудников и его стоимость отдельно от аудита.")]
        let second = valid.replacingOccurrences(of: "Провести аудит.", with: "Обсудили обучение сотрудников.")
            .replacingOccurrences(of: "decision", with: "topic").replacingOccurrences(of: "[0]", with: "[1]")
        InferenceFixture.largestAuditPrompt = 0
        InferenceFixture.queue = [try envelope(valid), try envelope(accepted), try envelope(second), try envelope(accepted.replacingOccurrences(of: "decision", with: "topic"))]
        controller.observe(multi, directory: nil)
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(controller.error.isEmpty && controller.record.summary?.citations.count == 2)
        precondition(controller.summaryText.contains("аудит") && controller.summaryText.contains("обучение"))
        precondition(InferenceFixture.largestAuditPrompt < 5000, "Audit must not duplicate source text inside fact JSON")
        precondition(InferenceFixture.queue.isEmpty)
        print("PASS: short explicit acceptance, invalid/duplicate indices, two-batch evidence and audit prompt budget")
        var isolated = MeetingSession(title: "Synthetic independent facts")
        isolated.state = .completed
        isolated.transcript = [
            TranscriptLine(source: .meeting, start: 0, end: 3, text: "Стоимость аудита 100 тысяч рублей."),
            TranscriptLine(source: .meeting, start: 4, end: 7, text: "Срок обучения 4 недели.")
        ]
        let independentFacts = #"{"facts":[{"kind":"topic","text":"Обсудили стоимость аудита: 100 тысяч рублей.","owner":"","deadline":"","sourceIDs":[0]},{"kind":"topic","text":"Упомянули срок обучения: 4 недели.","owner":"","deadline":"","sourceIDs":[1]}]}"#
        InferenceFixture.auditPrompts = []
        InferenceFixture.queue = [try envelope(independentFacts),
            try envelope(#"{"verdicts":{"0":{"supported":true,"meaningful":true,"kind":"topic"}}}"#),
            try envelope(#"{"verdicts":{"1":{"supported":true,"meaningful":true,"kind":"topic"}}}"#)]
        controller.observe(isolated, directory: nil)
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(InferenceFixture.auditPrompts.count == 2,
                     "Each fact must be audited separately so unrelated sources cannot contaminate its verdict")
        precondition(!InferenceFixture.auditPrompts[0].contains("Срок обучения") && !InferenceFixture.auditPrompts[1].contains("Стоимость аудита"))
        precondition(controller.error.isEmpty && controller.summaryText.contains("100") && controller.summaryText.contains("4 недели"))
        precondition(InferenceFixture.queue.isEmpty)
        print("PASS: independent facts use only their own evidence and preserve both price and duration")
        let completeSummary = controller.summaryText
        let missingMeaningful = #"{"verdicts":{"1":{"supported":true,"kind":"topic"}}}"#
        InferenceFixture.queue = [try envelope(independentFacts),
            try envelope(#"{"verdicts":{"0":{"supported":true,"meaningful":true,"kind":"topic"}}}"#),
            try envelope(missingMeaningful), try envelope(missingMeaningful)]
        controller.summarize()
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!controller.error.isEmpty && controller.summaryText == completeSummary && InferenceFixture.queue.isEmpty,
                     "Missing coherence verdict must fail closed without replacing the saved summary")
        InferenceFixture.queue = [try envelope(independentFacts),
            try envelope(#"{"verdicts":{"0":{"supported":true,"meaningful":true,"kind":"topic"}}}"#),
            try envelope(#"{"verdicts":{"1":{"supported":true,"meaningful":false,"kind":"topic"}}}"#)]
        controller.summarize()
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(controller.error.isEmpty && controller.summaryText.contains("100") && !controller.summaryText.contains("4 недели"),
                     "Rejecting an incoherent fact must retain independently accepted facts")
        print("PASS: missing coherence verdict preserves prior summary; mixed verdicts retain accepted facts")
        let beforeCancellation = controller.summaryText
        InferenceFixture.holdSecondAudit = true
        InferenceFixture.secondAuditHeld = false
        InferenceFixture.queue = [try envelope(independentFacts),
            try envelope(#"{"verdicts":{"0":{"supported":true,"meaningful":true,"kind":"topic"}}}"#)]
        controller.summarize()
        for _ in 0..<200 where !InferenceFixture.secondAuditHeld { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(controller.busySummary && InferenceFixture.secondAuditHeld)
        controller.cancelSummary()
        for _ in 0..<200 where InferenceFixture.secondAuditHeld { try await Task.sleep(nanoseconds: 10_000_000) }
        InferenceFixture.holdSecondAudit = false
        precondition(!controller.busySummary && !InferenceFixture.secondAuditHeld && controller.summaryText == beforeCancellation)
        precondition(InferenceFixture.queue.isEmpty)
        print("PASS: cancellation during the second fact audit cancels inference and preserves the complete saved summary")
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
