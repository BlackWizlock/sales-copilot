import SwiftUI
import CopilotCore

struct CalendarNotesView: View {
    let source: String
    private var paragraphs: [String] {
        CalendarNotes.markdown(source).components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                if paragraph.hasPrefix("#") {
                    Text(inline(paragraph.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)))
                        .font(.headline).padding(.top, 4)
                } else {
                    Text(inline(paragraph)).font(.callout).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func inline(_ text: String) -> AttributedString {
        var rendered = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        // Markdown may contain arbitrary schemes; only explicit HTTPS navigation is enabled.
        for run in Array(rendered.runs) {
            if let link = run.link, CalendarNotes.webURL(link.absoluteString) == nil { rendered[run.range].link = nil }
        }
        let plain = String(rendered.characters)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return rendered }
        // Reverse order keeps earlier offsets valid when replacing a long URL with its label.
        for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).reversed() {
            guard let url = match.url, let valid = CalendarNotes.webURL(url.absoluteString),
                  let range = Range(match.range, in: plain),
                  let start = AttributedString.Index(range.lowerBound, within: rendered),
                  let end = AttributedString.Index(range.upperBound, within: rendered) else { continue }
            var label = AttributedString(CalendarNotes.linkLabel(valid)); label.link = valid
            rendered.replaceSubrange(start..<end, with: label)
        }
        return rendered
    }
}
