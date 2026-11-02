import AppKit
import SwiftUI
import CopilotCore

@MainActor private final class CalendarEditorState: ObservableObject {
    @Published var text: NSAttributedString
    @Published var error: String?
    @Published var preview = false
    @Published var saving = false
    @Published var link = ""
    let sourceExceedsLimit: Bool
    weak var view: NSTextView?
    init(source: String) {
        sourceExceedsLimit = source.count > 10_000
        let markdown = (try? CalendarNotes.editableMarkdown(source)) ?? source
        let parsed = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
        let value = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        value.addAttribute(.font, value: NSFont.systemFont(ofSize: 14), range: NSRange(location: 0, length: value.length))
        for run in parsed.runs {
            guard let range = Range(run.range, in: String(parsed.characters)) else { continue }
            var font = NSFont.systemFont(ofSize: 14)
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if run.inlinePresentationIntent?.contains(.emphasized) == true { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            value.addAttribute(.font, value: font, range: NSRange(range, in: String(parsed.characters)))
        }
        value.enumerateAttribute(.link, in: NSRange(location: 0, length: value.length)) { raw, range, _ in
            if let raw, CalendarNotes.webURL(String(describing: raw)) == nil { value.removeAttribute(.link, range: range) }
        }
        text = value
        if sourceExceedsLimit { error = L10n.string("Описание длиннее 10 000 символов. Измените его в Битрикс24, чтобы сохранить весь текст.") }
    }
    func format(_ bold: Bool) {
        guard let view else { return }
        view.window?.makeFirstResponder(view)
        let manager = NSFontManager.shared
        let selected = view.selectedRange()
        let font = (selected.length > 0 ? view.textStorage?.attribute(.font, at: selected.location, effectiveRange: nil) : view.typingAttributes[.font]) as? NSFont ?? .systemFont(ofSize: 14)
        let trait: NSFontTraitMask = bold ? .boldFontMask : .italicFontMask
        let next = manager.traits(of: font).contains(trait) ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
        if selected.length == 0 { view.typingAttributes[.font] = next }
        else { view.textStorage?.addAttribute(.font, value: next, range: selected); text = view.attributedString() }
    }
    func list() {
        guard let view else { return }
        let range = (view.string as NSString).paragraphRange(for: view.selectedRange())
        let lines = (view.string as NSString).substring(with: range).components(separatedBy: "\n")
        let replacement = lines.enumerated().map { index, line in line.isEmpty && index == lines.count - 1 ? line : "• " + line }.joined(separator: "\n")
        view.insertText(replacement, replacementRange: range); text = view.attributedString()
    }
    func addLink() {
        guard let view, let url = CalendarNotes.webURL(link) else { error = L10n.string("Укажите ссылку HTTPS без логина и пароля"); return }
        let range = view.selectedRange()
        if range.length > 0 { view.textStorage?.addAttribute(.link, value: url, range: range); text = view.attributedString() }
        else { view.insertText(NSAttributedString(string: CalendarNotes.linkLabel(url), attributes: [.link: url, .font: NSFont.systemFont(ofSize: 14)]), replacementRange: range); text = view.attributedString() }
        link = ""; error = nil
    }
    var bbcode: String {
        var result = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var part = (text.string as NSString).substring(with: range)
            if let font = attributes[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) { part = "[b]" + part + "[/b]" }
                if traits.contains(.italicFontMask) { part = "[i]" + part + "[/i]" }
            }
            if let raw = attributes[.link], let url = CalendarNotes.webURL(String(describing: raw)) { part = "[url=" + url.absoluteString + "]" + part + "[/url]" }
            result += part
        }
        return result
    }
}

private struct CalendarRichText: NSViewRepresentable {
    @ObservedObject var state: CalendarEditorState
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = !state.sourceExceedsLimit
        text.isRichText = true; text.importsGraphics = false; text.allowsImageEditing = false
        text.isAutomaticLinkDetectionEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = true; text.isGrammarCheckingEnabled = true
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.textStorage?.setAttributedString(state.text); text.delegate = context.coordinator
        state.view = text
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(state) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let state: CalendarEditorState
        init(_ state: CalendarEditorState) { self.state = state }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = CalendarNotes.webURL(String(describing: link)) { NSWorkspace.shared.open(url) }
            return true
        }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            state.text = view.attributedString()
        }
    }
}

struct CalendarDescriptionEditor: View {
    let event: CalendarMeeting
    @ObservedObject var controller: CRMController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state: CalendarEditorState
    init(event: CalendarMeeting, controller: CRMController) {
        self.event = event; self.controller = controller
        _state = StateObject(wrappedValue: CalendarEditorState(source: event.raw["DESCRIPTION"]?.text ?? ""))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("Описание встречи")).font(.title2.bold())
            Text(event.title).font(.headline)
            Text(L10n.string("Сохранится описание только этой встречи в Битрикс24. Даты, участники и сделка останутся прежними.")).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(L10n.string("Жирный")) { state.format(true) }.disabled(state.preview)
                Button(L10n.string("Курсив")) { state.format(false) }.disabled(state.preview)
                Button(L10n.string("Список")) { state.list() }.disabled(state.preview)
                Spacer()
                Toggle(L10n.string("Предпросмотр"), isOn: $state.preview).toggleStyle(.button)
            }.disabled(state.saving)
            HStack {
                TextField("https://…", text: $state.link)
                Button(L10n.string("Добавить ссылку")) { state.addLink() }.disabled(state.link.isEmpty || state.preview)
            }.disabled(state.saving)
            if state.preview { ScrollView { CalendarNotesView(source: state.bbcode).padding(12) }.frame(minHeight: 240) }
            else { CalendarRichText(state: state).frame(minHeight: 240).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary)) }
            if let error = state.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text(L10n.string("Проверка орфографии доступна через меню текста. Автозамена выключена.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("Отмена")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(state.saving)
                Button(L10n.string("Сохранить в Битрикс24")) {
                    state.saving = true
                    Task {
                        do { try await controller.saveCalendarDescription(event, description: state.bbcode); dismiss() }
                        catch { state.error = L10n.error(error) }
                        state.saving = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(state.saving || state.sourceExceedsLimit || state.bbcode.count > 10_000 || controller.busy)
            }
        }.padding(24).frame(width: 720, height: 600).interactiveDismissDisabled(state.saving)
    }
}
