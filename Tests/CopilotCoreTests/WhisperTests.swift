import Foundation
import CopilotCore
final class WhisperTests {
    func testOffsetsAreRelativeToMeetingAndSilenceIsFiltered() throws {
        let data = Data(#"{"transcription":[{"offsets":{"from":100,"to":1200},"text":" Добрый день "},{"offsets":{"from":1200,"to":1800},"text":" [BLANK_AUDIO] "}]}"#.utf8)
        let lines = try WhisperOutput.parse(data, offset: 8, source: .microphone)
        expectEqual(lines.count, 1)
        expectEqual(lines[0].start, 8.1, accuracy: 0.001)
        expectEqual(lines[0].end, 9.2, accuracy: 0.001)
        expectEqual(lines[0].text, "Добрый день")
        expectEqual(lines[0].source, .microphone)
    }
    func testMalformedOutputFailsInsteadOfEmptySuccess() {
        expectThrows(try WhisperOutput.parse(Data("{}".utf8), offset: 0, source: .meeting))
    }
}
