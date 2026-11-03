import Foundation

public enum WhisperOutput {
    private struct Output: Decodable {
        struct Segment: Decodable {
            struct Offsets: Decodable { let from: Double; let to: Double }
            let offsets: Offsets
            let text: String
        }
        let transcription: [Segment]
    }
    public static func parse(_ data: Data, offset: Double, source: AudioSource) throws -> [TranscriptLine] {
        let result = try JSONDecoder().decode(Output.self, from: data)
        return result.transcription.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !["[BLANK_AUDIO]", "[SILENCE]", "[NO_SPEECH]"].contains(text.uppercased()) else { return nil }
            guard segment.offsets.to >= segment.offsets.from, segment.offsets.from >= 0 else { return nil }
            return TranscriptLine(source: source, start: offset + segment.offsets.from / 1000,
                                  end: offset + segment.offsets.to / 1000, text: text)
        }
    }
}
