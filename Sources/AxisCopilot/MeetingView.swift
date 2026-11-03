import SwiftUI
import CopilotCore

@MainActor private final class MeetingViewState: ObservableObject {
    @Published var tab = 1
    @Published var showCalendar = false
    @Published var showDeal = false
    @Published var showSpeakers = false
    @Published var deleting: MeetingSession?
}

struct MeetingView: View {
    @StateObject private var viewState = MeetingViewState()
    @ObservedObject var model: MeetingModel
    var body: some View {
        VStack(spacing: 0) {
            AxisBrandHeader()
            workspace
            AxisProductCredits()
        }
        .tint(AxisBrand.teal)
        .onReceive(NotificationCenter.default.publisher(for: .openCurrentCopilotMeeting)) { _ in
            viewState.showCalendar = false
        }
        .sheet(isPresented: $viewState.showDeal) { dealSheet }
        .alert(L10n.string("Удалить встречу?"), isPresented: Binding(get: { viewState.deleting != nil }, set: { if !$0 { viewState.deleting = nil } })) {
            Button(L10n.string("Удалить"), role: .destructive) {
                if let id = viewState.deleting?.id { model.deleteMeeting(id) }
                viewState.deleting = nil
            }
            Button(L10n.string("Отмена"), role: .cancel) { viewState.deleting = nil }
        } message: {
            Text(L10n.string("Аудио, транскрипция, материалы, резюме и чат будут удалены с этого Mac. Доступ MCP будет отозван. Уже отправленные данные в Битрикс24 сохранятся."))
        }
        .sheet(isPresented: $viewState.showSpeakers) {
            VStack { SpeakerPanel(model: model); Button(L10n.string("Готово")) { viewState.showSpeakers = false } }
                .padding(24).frame(width: 640, height: 380)
        }
    }
    private var workspace: some View {
        HSplitView {
            if let crm = model.crm {
                MeetingSidebar(model: model, crm: crm, showCalendar: $viewState.showCalendar) { viewState.deleting = $0 }
            }
            if viewState.showCalendar, let crm = model.crm {
                MeetingCalendarView(controller: crm, onSelectDeal: { id in
                    guard !model.locked else { return }
                    model.newMeeting()
                    Task { await crm.selectDeal(id); viewState.showCalendar = false; viewState.showDeal = true }
                }, onConnect: { CopilotSettingsWindow.shared.show(model: model, page: 3) }).frame(minWidth: 700, minHeight: 620)
            } else {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.current?.title ?? L10n.string("Новая встреча")).font(.title2.weight(.semibold)).lineLimit(1)
                    }
                    Spacer()
                    if let crm = model.crm {
                        DealBindingButton(controller: crm, session: model.current) { viewState.showDeal = true }
                    }
                    if model.current != nil {
                        Button(L10n.string("Участники"), systemImage: "person.2") { viewState.showSpeakers = true }
                    }
                    if model.phase == .recording { Text(model.elapsed).monospacedDigit().foregroundStyle(.secondary) }
                }
                if model.current == nil || model.phase != .idle {
                HStack {
                    TextField(L10n.string("Название встречи"), text: $model.title).textFieldStyle(.roundedBorder).disabled(model.locked)
                    Picker(L10n.string("Источник"), selection: $model.selectedPID) {
                        Text(L10n.string("Все приложения")).tag(Int32(0))
                        ForEach(model.applications, id: \.processID) { app in Text(app.applicationName).tag(app.processID) }
                    }.frame(maxWidth: 300).disabled(model.locked)
                    Button { Task { await model.refreshApplications() } } label: { Image(systemName: "arrow.clockwise") }
                        .help(L10n.string("Обновить приложения и проверить доступ к системному звуку")).disabled(model.locked || model.refreshing)
                }
                if model.selectedPID == 0 { Text(L10n.string("Будет записан звук всех приложений. Для изоляции встречи выберите Zoom, Телемост или браузер.")).font(.caption).foregroundStyle(.secondary) }
                if model.phase == .recording {
                    HStack(spacing: 16) { meter(.microphone); meter(.meeting) }
                }
                HStack(spacing: 12) {
                    if model.phase == .recording {
                        Button(L10n.string("Завершить запись"), systemImage: "stop.fill") { Task { await model.stop() } }.tint(.red).buttonStyle(.borderedProminent)
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text(L10n.string("Идёт запись")).foregroundStyle(.red)
                    } else {
                        Button(L10n.string("Начать встречу"), systemImage: "record.circle") { Task { await model.start() } }
                            .buttonStyle(.borderedProminent).disabled(model.locked)
                    }
                    if model.phase == .starting || model.phase == .stopping || model.processing || model.exporting { ProgressView().controlSize(.small) }
                    Spacer()
                    if model.current != nil {
                        Button(L10n.string("Повторить распознавание")) { model.retryTranscription() }.disabled(model.locked || (model.failed == 0 && model.pending == 0))
                    }
                }
                }
                if model.current == nil || model.phase != .idle || model.processing || model.exporting || model.failed > 0 || model.pending > 0 {
                    HStack {
                        Text(model.status + (model.pending > 0 ? L10n.format(" Осталось фрагментов: %@.", String(describing: model.pending)) : "")).font(.callout).foregroundStyle(.secondary)
                        if model.current != nil && model.phase == .idle && (model.failed > 0 || model.pending > 0) {
                            Spacer()
                            Button(L10n.string("Повторить распознавание")) { model.retryTranscription() }.disabled(model.locked)
                        }
                    }
                }
                if let error = model.error {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error).textSelection(.enabled).font(.callout)
                        Spacer()
                        Button(L10n.string("Скрыть")) { model.error = nil }
                    }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                MeetingMaterialsView(intelligence: model.intelligence)
                if model.phase == .recording || model.phase == .stopping {
                    LiveSalesHintView(intelligence: model.intelligence)
                }
                Divider()
                Picker(L10n.string("Раздел встречи"), selection: $viewState.tab) {
                    Text(L10n.string("Транскрипция")).tag(0)
                    Text(L10n.string("Резюме")).tag(1)
                    Text(L10n.string("Чат")).tag(2)
                }.pickerStyle(.segmented)
                if viewState.tab == 0 {
                    TranscriptPanel(model: model, playback: model.playback).frame(minHeight: 140, maxHeight: .infinity)
                } else {
                        IntelligencePanel(model: model.intelligence, session: model.current,
                                          sessionDirectory: model.current.flatMap { model.store?.directory($0.id) },
                                          seek: { seconds in
                                              if let line = model.current?.transcript.min(by: { abs($0.start - seconds) < abs($1.start - seconds) }) { model.play(line) }
                                          }, section: viewState.tab == 2 ? 1 : 0)
                        .frame(minHeight: 140, maxHeight: .infinity)
                }
                if model.current != nil {
                    PlaybackView(playback: model.playback, busy: model.phase != .idle || model.exporting, loading: model.preparingPlayback, hasEchoReduced: model.hasEchoReduced) { model.play() }
                }
            }.padding(28).frame(minWidth: 700, minHeight: 620).background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
    private func time(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(seconds)/60, Int(seconds)%60) }
    private func meter(_ source: AudioSource) -> some View {
        let receiving = ProcessInfo.processInfo.systemUptime - (model.lastSamples[source] ?? 0) < 2
        return Label(source == .microphone ? L10n.string("Микрофон") : L10n.string("Звук встречи"), systemImage: receiving ? "waveform" : "exclamationmark.circle")
            .font(.caption).foregroundStyle(receiving ? Color.secondary : Color.orange)
    }
    private var dealSheet: some View {
        VStack(spacing: 0) {
            HStack { Text("Сделка").font(.headline); Spacer(); Button(L10n.string("Готово")) { viewState.showDeal = false } }.padding()
            Divider()
            if let crm = model.crm {
                CRMPanel(controller: crm, session: model.current, summaryText: model.intelligence.summaryText,
                         audioURL: model.recordingURL,
                         prepareAudio: { try await model.prepareRecordingForCRM() },
                         onContextChanged: { text in
                             guard model.intelligence.record.dealText != text else { return }
                             model.intelligence.record.dealText = text; model.intelligence.updateContext()
                         })
            }
        }.frame(width: 760, height: 680)
    }
}
