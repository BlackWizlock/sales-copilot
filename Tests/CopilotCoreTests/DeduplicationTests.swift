import Foundation
import CopilotCore

struct DeduplicationTests {
    func run() {
        let remote = TranscriptLine(source: .meeting, start: 8, end: 12, text: "Обсудим план следующей встречи.")
        let echo = TranscriptLine(source: .microphone, start: 8.3, end: 12.3, text: "Обсудим план следующей встречи!")
        let genuine = TranscriptLine(source: .microphone, start: 18, end: 22, text: remote.text)
        let short = TranscriptLine(source: .microphone, start: 8.4, end: 9, text: "Да, да")
        let near = TranscriptLine(source: .microphone, start: 9, end: 13, text: "Обсудим план следующей поставки.")
        let result = TranscriptDeduplicator.visible([echo, remote, genuine, short, near])
        expectEqual(Set(result.map(\.id)), Set([remote, genuine, short, near].map(\.id)))
        expectEqual(TranscriptDeduplicator.visible([remote, remote]).count, 1)
        let differentRemote = TranscriptLine(source: .meeting, start: 8.1, end: 12.1, text: remote.text)
        expectEqual(TranscriptDeduplicator.visible([remote, differentRemote]).count, 2)
        let intentional = TranscriptLine(source: .microphone, start: 0, end: 2, text: "Очень очень важно")
        expectEqual(TranscriptDeduplicator.visible([intentional]).first?.text, intentional.text)
        print("PASS: cross-source echo text deduplication preserves distinct speech")
    }
}
