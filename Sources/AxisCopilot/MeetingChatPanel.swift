import SwiftUI
import CopilotCore

struct MeetingChatPanel: View {
    let session: MeetingSession?
    var seek: (Double) -> Void
    @ObservedObject var chat: MeetingChatController
    private var observationKey: String { session.map { IntelligenceSnapshot($0).fingerprint } ?? "none" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Вопросы по встрече")).font(.headline)
            if session == nil { Text(L10n.string("Выберите встречу, чтобы задать вопрос.")).foregroundStyle(.secondary) }
            else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if chat.messages.isEmpty {
                                Text(L10n.string("Например: о чём договорились и кто отвечает за следующий шаг?"))
                                    .foregroundStyle(.secondary).padding(.vertical, 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ForEach(chat.messages) { message in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(LocalizedStringKey(message.role == .question ? L10n.string("Вы") : L10n.string("По записи встречи"))).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    if message.state == .pending { ProgressView(L10n.string("Ищу ответ в транскрипции…")).controlSize(.small) }
                                    else { SummaryReadingView(text: message.text) }
                                    if message.role == .answer && message.fingerprint != chat.fingerprint { Text(L10n.string("Ответ относится к прежней версии транскрипции.")).font(.caption).foregroundStyle(.orange) }
                                    ForEach(message.citations) { citation in
                                        Button("\(Int(citation.seconds) / 60):\(String(format: "%02d", Int(citation.seconds) % 60))  \(citation.quote)") { seek(citation.seconds) }.buttonStyle(.link)
                                    }
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(message.role == .question ? Color.accentColor.opacity(0.07) : Color.secondary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            Color.clear.frame(height: 1).id("chat-bottom")
                        }
                    }.frame(minHeight: 140, maxHeight: .infinity)
                        .onChange(of: chat.messages.count) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
                        .onChange(of: chat.busy) { _, busy in if !busy { proxy.scrollTo("chat-bottom", anchor: .bottom) } }
                }
                Divider()
                TextEditor(text: $chat.input).font(.body).frame(height: 70).accessibilityLabel(L10n.string("Вопрос по встрече")).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Button(L10n.string("Задать вопрос")) { chat.ask() }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).disabled(!chat.canAsk)
                    if chat.busy { Button(L10n.string("Отменить ответ")) { chat.cancel() } }
                    Text(L10n.string("Только эта встреча · на Mac")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !chat.error.isEmpty { Text(chat.error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .onDisappear { chat.cancel() }
    }
}
