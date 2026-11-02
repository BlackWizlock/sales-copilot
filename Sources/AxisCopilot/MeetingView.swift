import SwiftUI
import CopilotCore

struct MeetingView: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        VStack(spacing: 0) {
            AxisBrandHeader()
            workspace
            AxisProductCredits()
        }
        .tint(AxisBrand.teal)
        .sheet(isPresented: $model.showSettings) { settings }
    }
    private var workspace: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 16) {
                Text("БИБЛИОТЕКА").font(.caption.weight(.semibold)).foregroundStyle(AxisBrand.teal)
                Text("Встречи").font(.largeTitle.weight(.semibold))
                Text("Запись и текст хранятся на этом Mac.").font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.sessions) { session in
                            Button { model.select(session.id) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(session.title).font(.headline).lineLimit(1)
                                    Text(session.created, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                    if session.state == .interrupted { Text("Прервана · аудио сохранено").font(.caption).foregroundStyle(.orange) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(model.current?.id == session.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).disabled(model.locked)
                        }
                    }
                }
                Spacer(minLength: 0)
                Button("Настройки распознавания", systemImage: "slider.horizontal.3") { model.showSettings = true }
                Button("Открыть папку записей", systemImage: "folder") { model.revealFolder() }
            }.padding(20).frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                .background(Color(nsColor: .windowBackgroundColor))
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Запись встречи").font(.largeTitle.weight(.semibold))
                        Text("Русская транскрипция · локальная модель · прототип A").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.elapsed).font(.system(.title, design: .monospaced)).monospacedDigit()
                }
                HStack {
                    TextField("Название встречи", text: $model.title).textFieldStyle(.roundedBorder).disabled(model.locked)
                    Picker("Источник", selection: $model.selectedPID) {
                        Text("Все приложения").tag(Int32(0))
                        ForEach(model.applications, id: \.processID) { app in Text(app.applicationName).tag(app.processID) }
                    }.frame(maxWidth: 300).disabled(model.locked)
                    Button { Task { await model.refreshApplications() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Обновить приложения и проверить доступ к системному звуку").disabled(model.locked || model.refreshing)
                }
                if model.selectedPID == 0 { Text("Будет записан звук всех приложений. Для изоляции встречи выберите Zoom, Телемост или браузер.").font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 16) {
                    meter(.microphone); meter(.meeting)
                }
                HStack(spacing: 12) {
                    if model.phase == .recording {
                        Button("Завершить запись", systemImage: "stop.fill") { Task { await model.stop() } }.tint(.red).buttonStyle(.borderedProminent)
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("Идёт запись").foregroundStyle(.red)
                    } else {
                        Button("Начать встречу", systemImage: "record.circle") { Task { await model.start() } }
                            .buttonStyle(.borderedProminent).disabled(model.locked)
                    }
                    if model.phase == .starting || model.phase == .stopping || model.processing || model.exporting { ProgressView().controlSize(.small) }
                    Spacer()
                    if model.current != nil {
                        Button("Слушать", systemImage: "play.fill") { model.play() }.disabled(model.phase != .idle)
                        Button("Повторить распознавание") { model.retryTranscription() }.disabled(model.locked || (model.failed == 0 && model.pending == 0))
                    }
                }
                Text(model.status + (model.pending > 0 ? " Осталось фрагментов: \(model.pending)." : "")).font(.callout).foregroundStyle(.secondary)
                if let error = model.error {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error).textSelection(.enabled).font(.callout)
                        Spacer()
                        Button("Скрыть") { model.error = nil }
                    }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                Divider()
                HStack { Text("Транскрипция").font(.title2.weight(.medium)); Spacer(); Text("Нажмите время, чтобы прослушать").font(.caption).foregroundStyle(.secondary) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if model.current?.transcript.isEmpty != false {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Здесь появится текст разговора").font(.headline)
                                    Text("Первые фрагменты обрабатываются после накопления 8 секунд звука. После остановки распознавание продолжится.").foregroundStyle(.secondary)
                                }.padding(.vertical, 28)
                            }
                            ForEach(model.current?.transcript ?? []) { line in
                                HStack(alignment: .top, spacing: 14) {
                                    Button(time(line.start)) { model.play(line) }.buttonStyle(.plain).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 48)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(line.source.title).font(.caption.weight(.semibold)).foregroundStyle(line.source == .microphone ? Color.accentColor : .secondary)
                                        Text(line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.id(line.id)
                            }
                        }.padding(.vertical, 8)
                    }.onChange(of: model.current?.transcript.count) { _, _ in
                        if model.phase == .recording, let id = model.current?.transcript.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                Text("КП, суфлёр и Битрикс24 появятся в следующих срезах. Аудио в облако не отправляется.").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(minWidth: 700, minHeight: 620).background(Color(nsColor: .textBackgroundColor))
        }
    }
    private func time(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(seconds)/60, Int(seconds)%60) }
    private func meter(_ source: AudioSource) -> some View {
        let receiving = ProcessInfo.processInfo.systemUptime - (model.lastSamples[source] ?? 0) < 2
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(source == .microphone ? "Микрофон · я" : "Звук встречи · собеседники").font(.callout.weight(.medium))
                Spacer()
                Text(model.phase == .recording ? (receiving ? "Поток есть" : "Нет потока") : "Ожидание").font(.caption).foregroundStyle(receiving && model.phase == .recording ? Color.green : .secondary)
            }
            ProgressView(value: receiving && model.phase == .recording ? min(1, Double(model.levels[source] ?? 0) * 8) : 0).tint(source == .microphone ? .accentColor : .green)
        }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Локальное распознавание").font(.title2.weight(.semibold))
            Text("Многоязычная модель Whisper хранится на Mac. Платные API не используются.").foregroundStyle(.secondary)
            TextField("Путь к whisper-cli", text: $model.executablePath)
            TextField("Путь к модели .bin", text: $model.modelPath)
            HStack {
                Button("Выбрать модель") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { model.modelPath = url.path }
                }
                Spacer()
                Button("Сохранить") { model.saveSettings(); model.showSettings = false }.keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(28).frame(width: 620).disabled(model.locked)
    }
}
