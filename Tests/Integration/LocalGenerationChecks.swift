import Foundation
import CopilotCore

/// Synthetic OpenRouter wire responses; never contacts a model or reads credentials.
private final class InferenceFixture: URLProtocol {
    nonisolated(unsafe) static var paths: [String] = []
    nonisolated(unsafe) static var reply = Data()
    nonisolated(unsafe) static var generationBody: [String: Any] = [:]
    nonisolated(unsafe) static var queue: [Data] = []
    nonisolated(unsafe) static var oversizedExtraction = false
    nonisolated(unsafe) static var largestAuditPrompt = 0
    nonisolated(unsafe) static var auditPrompts: [String] = []
    nonisolated(unsafe) static var holdSecondAudit = false
    nonisolated(unsafe) static var secondAuditHeld = false
    nonisolated(unsafe) static var cloudHeld = false
    private var withheld = false
    override class func canInit(with request: URLRequest) -> Bool {
        true // Intercept every URL; a wrong host must fail here, never reach the network.
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.host == "openrouter.ai" && request.url?.scheme == "https")
        Self.paths.append(request.url!.path)
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
           let messages = value["messages"] as? [[String: Any]], let prompt = messages.last?["content"] as? String {
            Self.generationBody = value
            if prompt == "Hold cloud request" { Self.cloudHeld = true; withheld = true; return }
            if prompt.contains("ORIGINAL SOURCES:") { Self.largestAuditPrompt = max(Self.largestAuditPrompt, prompt.count); Self.auditPrompts.append(prompt) }
            if Self.holdSecondAudit && prompt.hasPrefix("FACT 1\n") {
                Self.secondAuditHeld = true; withheld = true; return
            }
            if prompt != "Synthetic", !prompt.contains("ORIGINAL SOURCES:"), let responseFormat = value["response_format"] as? [String: Any],
               let jsonSchema = responseFormat["json_schema"] as? [String: Any], let format = jsonSchema["schema"] as? [String: Any],
               let properties = format["properties"] as? [String: Any] {
                let bounds = ["commitments", "topics"].compactMap { (properties[$0] as? [String: Any])?["maxItems"] as? Int }
                if bounds != [3, 3] { Self.oversizedExtraction = true }
            }
        }
        let catalog = Data(#"{"data":[{"id":"synthetic/model","name":"Synthetic","pricing":{"prompt":"0.000001","completion":"0.000002","request":"0"},"supported_parameters":["max_tokens","response_format","structured_outputs"]},{"id":"json-only","name":"JSON only","pricing":{"prompt":"0.000001","completion":"0.000002","request":"0"},"supported_parameters":["max_tokens","response_format"]}]}"#.utf8)
        let data = request.url?.path == "/api/v1/models" ? catalog : (Self.queue.isEmpty ? Self.reply : Self.queue.removeFirst())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { if withheld { Self.secondAuditHeld = false; Self.cloudHeld = false } }
}

@main struct LocalGenerationChecks {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InferenceFixture.self]
        let network = URLSession(configuration: config)
        let suiteName = "axis-generation-fixture-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let connection = OpenRouterSandbox(defaults: defaults, network: network, keyReader: { "synthetic-key" })
        let unconfigured = IntelligenceRuntime(connection: connection)
        let runtime = IntelligenceRuntime(generator: { system, prompt, schema, tokens in
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.httpBody = try OpenRouterCompletion.body(model: "synthetic/model", system: system, prompt: prompt, schema: schema, maximumTokens: tokens, prices: (0, 0, 0))
            let (data, _) = try await network.data(for: request)
            return try OpenRouterCompletion.decode(data)
        }, model: "synthetic/model")
        InferenceFixture.reply = Data()
        do {
            _ = try await unconfigured.generate(system: "Synthetic", prompt: "Synthetic")
            throw CopilotError.message("FAIL: unconfigured application started inference")
        } catch let error as CopilotError {
            guard !error.localizedDescription.hasPrefix("FAIL:") else { throw error }
        }
        precondition(InferenceFixture.paths.isEmpty, "Disabled inference must not access the network")
        connection.meetingsEnabled = true; connection.selectedModel = "synthetic/model"
        do {
            _ = try await unconfigured.generate(system: "Synthetic", prompt: "Synthetic")
            throw CopilotError.message("FAIL: zero budget allowed inference")
        } catch let error as CopilotError {
            guard !error.localizedDescription.hasPrefix("FAIL:") else { throw error }
        }
        precondition(InferenceFixture.paths.isEmpty, "Zero budget must block before any request")
        connection.budgetText = "1"
        InferenceFixture.reply = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": "{}"]]], "usage": ["cost": 0.002]])
        let routed = try await unconfigured.generate(system: "Synthetic", prompt: "Synthetic", schema: ["type": "object", "properties": [:], "additionalProperties": false])
        precondition(routed == "{}" && InferenceFixture.paths == ["/api/v1/models", "/api/v1/chat/completions"])
        precondition(connection.chargedText == "0.002", "Usage must reconcile the durable reservation")
        let restored = OpenRouterSandbox(defaults: defaults, network: network, keyReader: { "synthetic-key" })
        precondition(restored.selectedModel == "synthetic/model" && restored.meetingsEnabled && restored.chargedText == "0.002")
        connection.budgetText = "0.002"
        let calls = InferenceFixture.paths.count
        do {
            _ = try await unconfigured.generate(system: "Synthetic", prompt: "Synthetic")
            throw CopilotError.message("FAIL: exhausted budget allowed inference")
        } catch let error as CopilotError {
            guard !error.localizedDescription.hasPrefix("FAIL:") else { throw error }
        }
        precondition(InferenceFixture.paths.count == calls, "Exhausted budget must not submit a completion")
        connection.budgetText = "1"
        InferenceFixture.reply = Data(#"{"choices":[{"finish_reason":"length","message":{"content":"{}"}}]}"#.utf8)
        do {
            _ = try await unconfigured.generate(system: "Synthetic", prompt: "Synthetic")
            throw CopilotError.message("FAIL: truncated cloud output was accepted")
        } catch let error as CopilotError {
            guard !error.localizedDescription.hasPrefix("FAIL:") else { throw error }
        }
        precondition(Decimal(string: connection.chargedText)! > Decimal(string: "0.002")!, "Unknown charges must retain their durable reservation")
        let missingKey = OpenRouterSandbox(defaults: defaults, network: network, keyReader: { nil })
        await missingKey.loadModels()
        let beforeMissingKey = InferenceFixture.paths.count
        do {
            _ = try await IntelligenceRuntime(connection: missingKey).generate(system: "Synthetic", prompt: "Synthetic")
            throw CopilotError.message("FAIL: missing key allowed inference")
        } catch let error as CopilotError {
            guard !error.localizedDescription.hasPrefix("FAIL:") else { throw error }
        }
        precondition(InferenceFixture.paths.count == beforeMissingKey, "A missing key must never submit meeting text")
        precondition(connection.meetingModels.map(\.id) == ["synthetic/model"], "JSON mode alone must not qualify for strict schema generation")
        connection.selectedModel = "json-only"
        do {
            _ = try await unconfigured.generate(system: "Synthetic", prompt: "Synthetic")
            throw CopilotError.message("FAIL: JSON-only model allowed strict schema inference")
        } catch let error as CopilotError {
            guard !error.localizedDescription.hasPrefix("FAIL:") else { throw error }
        }
        precondition(InferenceFixture.paths.count == beforeMissingKey)
        connection.selectedModel = "synthetic/model"
        for changeModel in [false, true] {
            connection.meetingsEnabled = true
            let pending = Task { try await unconfigured.generate(system: "Synthetic", prompt: "Hold cloud request") }
            for _ in 0..<100 {
                if InferenceFixture.cloudHeld { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            precondition(InferenceFixture.cloudHeld)
            let reserved = connection.chargedText
            if changeModel { connection.selectedModel = "json-only" } else { connection.meetingsEnabled = false }
            do { _ = try await pending.value; preconditionFailure("Disabled cloud request was not cancelled") }
            catch is CancellationError {} catch { throw error }
            precondition(connection.chargedText == reserved, "Cancellation must not erase unknown charges")
            connection.selectedModel = "synthetic/model"
        }
        print("PASS: application routes through OpenRouter; disabled/zero/exhausted budget blocks requests; model and charges persist")
        for body in [
            #"{"choices":[{"finish_reason":"length","message":{"content":"{}"}}]}"#,
            #"{"choices":[{"message":{"content":"{}"}}]}"#
        ] {
            InferenceFixture.reply = Data(body.utf8)
            do {
                _ = try await runtime.generate(system: "Synthetic", prompt: "Synthetic")
                throw CopilotError.message("FAIL: unfinished model output was accepted")
            } catch let error as CopilotError {
                guard !error.localizedDescription.hasPrefix("FAIL:") else { throw error }
            }
        }
        InferenceFixture.reply = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": #"{"overview":"Complete"}"#]]]])
        let complete = try await runtime.generate(system: "Synthetic", prompt: "Synthetic")
        precondition(complete == #"{"overview":"Complete"}"#)
        precondition(InferenceFixture.generationBody["model"] as? String == "synthetic/model")
        precondition(InferenceFixture.generationBody["response_format"] != nil,
                     "Meeting generation must preserve structured output validation")
        let provider = InferenceFixture.generationBody["provider"] as! [String: Any]
        precondition(provider["allow_fallbacks"] as? Bool == false && provider["data_collection"] as? String == "deny")
        print("PASS: unfinished inference rejected; complete structured response preserved")
        var session = MeetingSession(title: "Synthetic")
        session.state = .completed
        session.transcript = [TranscriptLine(source: .meeting, start: 0, end: 3, text: "На встрече договорились провести аудит.")]
        let valid = """
        {"facts":[{"kind":"decision","text":"Провести аудит.","owner":"","deadline":"","sourceIDs":[0]}]}
        """
        let indexed = try JSONDecoder().decode(GroundedMeetingNotes.IndexedDraft.self, from: Data(valid.utf8))
        let resolved = indexed.grounded(in: session.transcript)
        precondition(resolved.facts[0].evidence[0].quote == session.transcript[0].text)
        precondition(resolved.facts[0].evidence[0].segmentID == session.transcript[0].id)
        precondition(indexed.grounded(in: session.transcript, allowedSourceIDs: []).facts[0].evidence.isEmpty,
                     "A source outside the current batch cannot support a fact")
        let accepted = #"{"verdicts":{"0":{"supported":true,"meaningful":true,"owner":"","deadline":"","kind":"decision"}}}"#
        let shortLines = [TranscriptLine(source: .meeting, start: 0, end: 1, text: "Предлагаю провести аудит."),
                          TranscriptLine(source: .microphone, start: 1, end: 2, text: "Да.")]
        let shortDraft = valid.replacingOccurrences(of: "[0]", with: "[0,1]")
        let shortResolved = try JSONDecoder().decode(GroundedMeetingNotes.IndexedDraft.self, from: Data(shortDraft.utf8)).grounded(in: shortLines)
        let shortAudit = try JSONDecoder().decode(GroundedMeetingNotes.Audit.self, from: Data(#"{"verdicts":[{"index":0,"supported":true,"meaningful":true,"owner":"","deadline":"","kind":"decision"}]}"#.utf8))
        precondition(shortResolved.validated(in: shortLines, audit: shortAudit).facts.count == 1,
                     "An exact short acceptance must not erase an explicit agreement")
        let rejected = #"{"verdicts":{"0":{"supported":false,"meaningful":true,"owner":"","deadline":"","kind":"decision"}}}"#
        func envelope(_ value: String) throws -> Data {
            // Historical fixture facts retain their core-decoder tests above;
            // generation fixtures use the new explicit section contract.
            var response = value
            if let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
               let facts = object["facts"] as? [[String: Any]] {
                response = String(decoding: try JSONSerialization.data(withJSONObject: [
                    "commitments": facts.filter { $0["kind"] as? String != "topic" },
                    "topics": facts.filter { $0["kind"] as? String == "topic" }]), as: UTF8.self)
            }
            return try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": response]]]])
        }
        InferenceFixture.queue = [try envelope(#"{"facts":[]}"#), try envelope(accepted)]
        var coverageSession = session
        coverageSession.transcript[0].text = "Договорились провести аудит."
        let coveredDecision = try await GroundedSummaryGenerator(runtime: runtime).generate(IntelligenceSnapshot(coverageSession)) { _ in }
        precondition(coveredDecision.decisions.contains { $0.contains("аудит") },
                     "An explicit standalone source agreement must survive omission by generic extraction")
        print("PASS: explicit source agreement survives omission by generic extraction")
        var compoundSession = session
        compoundSession.transcript[0].text = "Договорились провести аудит и Анна отправит список сотрудников в пятницу."
        let compoundAction = #"{"facts":[{"kind":"action","text":"Анна отправит список сотрудников в пятницу","owner":"Анна","deadline":"в пятницу","sourceIDs":[0]}]}"#
        let compoundAudit = #"{"verdicts":{"1":{"supported":true,"meaningful":true,"owner":"Анна","deadline":"в пятницу","kind":"action"}}}"#
        InferenceFixture.queue = [try envelope(compoundAction), try envelope(accepted), try envelope(compoundAudit)]
        let compound = try await GroundedSummaryGenerator(runtime: runtime).generate(IntelligenceSnapshot(compoundSession)) { _ in }
        precondition(compound.actions.contains { $0.owner == "Анна" && $0.deadline == "в пятницу" },
                     "Source coverage must preserve a separate action supported by the same quotation")
        print("PASS: source agreement coverage retains separate actions sharing its quotation")
        InferenceFixture.queue = [try envelope("{"), try envelope(valid), try envelope(accepted)]
        let controller = LocalIntelligence(runtime: runtime)
        controller.observe(session, directory: nil)
        precondition(!controller.busySummary, "Opening an archived meeting must not start paid cloud generation")
        controller.summarize()
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
        InferenceFixture.queue = [try envelope(incoherentFact), try envelope(#"{"verdicts":{"0":{"supported":true,"meaningful":false,"owner":"","deadline":"","kind":"topic"}}}"#)]
        controller.observe(incoherent, directory: nil)
        controller.summarize()
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!controller.error.isEmpty && !controller.summaryText.contains("протеин"),
                     "A literally quoted but incoherent recognition fragment must not become a meaningful summary topic")
        InferenceFixture.queue = [try envelope(valid), try envelope(accepted)]
        controller.observe(session, directory: nil)
        controller.summarize()
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
        controller.summarize()
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
        controller.summarize()
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
            try envelope(#"{"verdicts":{"0":{"supported":true,"meaningful":true,"owner":"","deadline":"","kind":"topic"}}}"#),
            try envelope(#"{"verdicts":{"1":{"supported":true,"meaningful":true,"owner":"","deadline":"","kind":"topic"}}}"#)]
        controller.observe(isolated, directory: nil)
        controller.summarize()
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
            try envelope(#"{"verdicts":{"0":{"supported":true,"meaningful":true,"owner":"","deadline":"","kind":"topic"}}}"#),
            try envelope(missingMeaningful), try envelope(missingMeaningful)]
        controller.summarize()
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!controller.error.isEmpty && controller.summaryText == completeSummary && InferenceFixture.queue.isEmpty,
                     "Missing coherence verdict must fail closed without replacing the saved summary")
        InferenceFixture.queue = [try envelope(independentFacts),
            try envelope(#"{"verdicts":{"0":{"supported":true,"meaningful":true,"owner":"","deadline":"","kind":"topic"}}}"#),
            try envelope(#"{"verdicts":{"1":{"supported":true,"meaningful":false,"owner":"","deadline":"","kind":"topic"}}}"#)]
        controller.summarize()
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(controller.error.isEmpty && controller.summaryText.contains("100") && !controller.summaryText.contains("4 недели"),
                     "Rejecting an incoherent fact must retain independently accepted facts")
        print("PASS: missing coherence verdict preserves prior summary; mixed verdicts retain accepted facts")
        let beforeCancellation = controller.summaryText
        InferenceFixture.holdSecondAudit = true
        InferenceFixture.secondAuditHeld = false
        InferenceFixture.queue = [try envelope(independentFacts),
            try envelope(#"{"verdicts":{"0":{"supported":true,"meaningful":true,"owner":"","deadline":"","kind":"topic"}}}"#)]
        controller.summarize()
        for _ in 0..<200 where !InferenceFixture.secondAuditHeld { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(controller.busySummary && InferenceFixture.secondAuditHeld)
        controller.cancelSummary()
        for _ in 0..<200 where InferenceFixture.secondAuditHeld { try await Task.sleep(nanoseconds: 10_000_000) }
        InferenceFixture.holdSecondAudit = false
        precondition(!controller.busySummary && !InferenceFixture.secondAuditHeld && controller.summaryText == beforeCancellation)
        precondition(InferenceFixture.queue.isEmpty)
        print("PASS: cancellation during the second fact audit cancels inference and preserves the complete saved summary")
        var promised = session
        promised.id = UUID()
        promised.transcript = [TranscriptLine(source: .meeting, start: 0, end: 3, text: "Да, я тогда пробью площадку.")]
        let splitDraft = #"{"commitments":[{"kind":"action","text":"Проверить площадку.","owner":"","deadline":"","sourceIDs":[0]}],"topics":[]}"#
        InferenceFixture.queue = [try envelope(splitDraft), try envelope(actionAudit)]
        controller.observe(promised, directory: nil)
        controller.summarize()
        for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(controller.error.isEmpty && controller.summaryText.contains("Проверить площадку."),
                     "Dedicated commitment extraction must retain a concrete current promise")
        let promisedSummary = controller.summaryText
        for bad in [#"{"topics":[]}"#,
                    splitDraft.replacingOccurrences(of: "\"kind\":\"action\"", with: "\"kind\":\"topic\"")] {
            InferenceFixture.queue = [try envelope(bad), try envelope(bad)]
            controller.summarize()
            for _ in 0..<200 where controller.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(!controller.error.isEmpty && controller.summaryText == promisedSummary,
                         "Missing commitment section or wrong category must preserve the complete previous summary")
            InferenceFixture.queue = []
        }
        print("PASS: separate commitment/topic sections preserve promises and reject malformed category boundaries")
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
        InferenceFixture.queue = [try envelope(valid), try envelope(accepted)]
        let automatic = LocalIntelligence(runtime: runtime)
        var processing = session; processing.state = .processing
        automatic.observe(processing, directory: nil)
        precondition(!automatic.busySummary)
        automatic.observe(session, directory: nil)
        precondition(automatic.busySummary, "Finishing the current meeting must retain automatic summary generation")
        for _ in 0..<200 where automatic.busySummary { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(automatic.error.isEmpty && automatic.record.summary != nil)
        print("PASS: archive opening stays offline while completion of the current meeting starts its summary")
    }
}
