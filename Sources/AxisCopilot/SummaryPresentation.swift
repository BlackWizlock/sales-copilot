import SwiftUI

/// Render blocks separately so headings and lists remain compact and readable on macOS.
struct SummaryReadingView: View {
    let text: String
    private struct Block: Identifiable { let id: Int; let kind: Int; let text: String }
    private var blocks: [Block] {
        var result: [Block] = []; var paragraph: [String] = []
        func flush() { if !paragraph.isEmpty { result.append(Block(id: result.count, kind: 0, text: paragraph.joined(separator: "\n"))); paragraph = [] } }
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("#") { flush(); result.append(Block(id: result.count, kind: 1, text: line.drop(while: { $0 == "#" || $0 == " " }).description)) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { flush(); result.append(Block(id: result.count, kind: 2, text: String(line.dropFirst(2)))) }
            else if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() }
            else { paragraph.append(line) }
        }
        flush(); return result
    }
    private func inline(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                if block.kind == 1 { Text(inline(block.text)).font(.headline).padding(.top, 4) }
                else if block.kind == 2 {
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(.secondary); Text(inline(block.text)).frame(maxWidth: .infinity, alignment: .leading) }
                } else { Text(inline(block.text)).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }.textSelection(.enabled).lineSpacing(3)
    }
}
