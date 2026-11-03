import Foundation

public struct StructuredMeetingSummary: Codable {
    public struct Action: Codable {
        public var task: String
        public var owner: String
        public var deadline: String
        public init(task: String, owner: String, deadline: String) { self.task = task; self.owner = owner; self.deadline = deadline }
    }
    public struct Citation: Codable { public var segmentID: UUID; public var quote: String }
    public var overview: String
    public var decisions: [String]
    public var actions: [Action]
    public var questions: [String]
    public var citations: [Citation]
    public init(overview: String, decisions: [String], actions: [Action], questions: [String], citations: [Citation]) {
        self.overview = overview; self.decisions = decisions; self.actions = actions; self.questions = questions; self.citations = citations
    }
    public var markdown: String {
        func list(_ values: [String]) -> String { values.isEmpty ? "Не зафиксировано." : values.map { "- " + $0 }.joined(separator: "\n") }
        let steps = actions.map { action in
            action.task + (action.owner.isEmpty ? " · ответственный не назван" : " · " + action.owner)
            + (action.deadline.isEmpty ? " · срок не назван" : " · " + action.deadline)
        }
        return "## Итог\n\n" + overview + "\n\n## Договорённости\n\n" + list(decisions)
            + "\n\n## Следующие шаги\n\n" + list(steps) + "\n\n## Открытые вопросы\n\n" + list(questions)
    }
}
