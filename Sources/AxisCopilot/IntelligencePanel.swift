import SwiftUI
import AppKit
import CopilotCore

@MainActor private final class IntelligencePanelState: ObservableObject {
    @Published var editing = false
    @Published var draft = ""
}

struct IntelligencePanel: View {
    @ObservedObject var model: LocalIntelligence
    let session: MeetingSession?
    let sessionDirectory: URL?
    var seek: (Double) -> Void = { _ in }
    var section: Int = 0
    var saveSummary: ((MeetingSummary) -> Void)? = nil
    @StateObject private var ui = IntelligencePanelState()
    private var observationKey: String {
        guard let session else { return "none" }
        return IntelligenceSnapshot(session).fingerprint + session.state.rawValue + session.chunks.map { $0.state.rawValue }.joined()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if session != nil {
                if section == 1 {
                    MeetingChatPanel(session: session, seek: seek, chat: model.chat)
                } else {
                    ScrollView { analysis.frame(maxWidth: .infinity, alignment: .leading) }
                }
            } else {
                Text(L10n.string("Добавьте материалы перед встречей или выберите запись для разбора.")).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .onAppear { model.observe(session, directory: sessionDirectory, saveSummary: saveSummary) }
        .onChange(of: observationKey) { _, _ in ui.editing = false; model.observe(session, directory: sessionDirectory, saveSummary: saveSummary) }
    }
    private var analysis: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.string("Резюме встречи")).font(.title2.weight(.semibold))
                Spacer()
                if !model.summaryText.isEmpty {
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.summaryText, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help(L10n.string("Копировать"))
                    if !ui.editing { Button(L10n.string("Редактировать")) { ui.draft = model.summaryText; ui.editing = true }.disabled(model.busySummary) }
                }
                Button(LocalizedStringKey(model.summaryText.isEmpty ? L10n.string("Составить") : L10n.string("Обновить"))) { model.summarize() }.disabled(model.busySummary || model.snapshot?.canSummarize != true)
            }
            if model.busySummary { ProgressView(L10n.string("Готовлю итоги и следующие шаги…")).controlSize(.small) }
            if !model.summaryText.isEmpty {
                if ui.editing {
                    TextEditor(text: $ui.draft).frame(minHeight: 240)
                    HStack {
                        Button(L10n.string("Сохранить правки")) { model.summaryText = ui.draft; model.saveEdits(); ui.editing = false }
                        Button(L10n.string("Отмена")) { ui.editing = false }
                    }
                } else { SummaryReadingView(text: model.summaryText) }
                if !(model.record.summary?.citations.isEmpty ?? true) {
                    DisclosureGroup(L10n.string("Фразы из записи")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.record.summary?.citations ?? []) { citation in
                                Button("\(Int(citation.seconds) / 60):\(String(format: "%02d", Int(citation.seconds) % 60))  \(citation.quote)") { seek(citation.seconds) }.buttonStyle(.link)
                            }
                        }.padding(.top, 6)
                    }
                }
            } else if !model.busySummary { Text(L10n.string("После завершения записи здесь появятся итоги, договорённости и следующие шаги.")).foregroundStyle(.secondary).padding(.vertical, 16) }
        }
    }
}
