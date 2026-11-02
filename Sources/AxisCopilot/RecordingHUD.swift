import AppKit
import SwiftUI
import Combine
import CopilotCore

extension Notification.Name {
    static let openCurrentCopilotMeeting = Notification.Name("AxisCopilot.openCurrentMeeting")
}

@MainActor final class RecordingHUDController: ObservableObject {
    @Published private(set) var isExpanded = false
    private let model: MeetingModel
    private weak var mainWindow: NSWindow?
    private var panel: NSPanel?
    private var phaseObserver: AnyCancellable?
    private var hintObserver: AnyCancellable?
    private var active = false
    var isVisible: Bool { panel?.isVisible == true }

    init(model: MeetingModel) {
        self.model = model
        phaseObserver = model.$phase.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.synchronize() }
        }
        hintObserver = model.intelligence.$suggestion.removeDuplicates().sink { [weak self] suggestion in
            guard !suggestion.isEmpty else { return }
            Task { @MainActor in
                guard let self, self.active else { return }
                self.setExpanded(true)
                self.panel?.orderFrontRegardless()
            }
        }
    }

    func attach(mainWindow: NSWindow) { self.mainWindow = mainWindow }

    private func synchronize() {
        switch model.phase {
        case .recording:
            guard !active else { return }
            active = true
            setExpanded(false)
            if panel == nil { createPanel() }
            panel?.orderFrontRegardless()
            // Keep the meeting app in front. Only hide our registered document window.
            mainWindow?.orderOut(nil)
        case .idle:
            guard active else { return }
            active = false
            panel?.orderOut(nil)
            showMeeting()
        case .starting, .stopping: break
        }
    }

    func showMeeting() {
        setExpanded(false)
        NotificationCenter.default.post(name: .openCurrentCopilotMeeting, object: nil)
        if let mainWindow {
            mainWindow.deminiaturize(nil)
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        guard let panel else { return }
        let size = expanded ? NSSize(width: 420, height: 490) : NSSize(width: 150, height: 52)
        let old = panel.frame
        var frame = NSRect(x: old.maxX - size.width, y: old.maxY - size.height, width: size.width, height: size.height)
        if let bounds = panel.screen?.visibleFrame {
            frame.origin.x = max(bounds.minX, min(frame.minX, bounds.maxX - frame.width))
            frame.origin.y = max(bounds.minY, min(frame.minY, bounds.maxY - frame.height))
        }
        panel.setFrame(frame, display: true)
    }

    private func createPanel() {
        let bounds = mainWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let panel = NSPanel(contentRect: NSRect(x: bounds.maxX - 174, y: bounds.maxY - 76, width: 150, height: 52),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L10n.string("Управление записью")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: RecordingHUDView(model: model, controller: self, intelligence: model.intelligence))
        self.panel = panel
    }
}

private struct RecordingHUDView: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var controller: RecordingHUDController
    @ObservedObject var intelligence: LocalIntelligence
    @ObservedObject private var language = UILanguageSettings.shared
    private let teal = Color(red: 36 / 255, green: 145 / 255, blue: 155 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { controller.setExpanded(!controller.isExpanded) } label: {
                HStack(spacing: 9) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 24)).foregroundStyle(teal)
                    equalizer
                    Text(model.elapsed).font(.system(.caption, design: .monospaced)).monospacedDigit()
                    if controller.isExpanded { Spacer(minLength: 0); Image(systemName: "chevron.up").font(.caption2) }
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.isExpanded ? Text(L10n.string("Свернуть управление записью")) : Text(L10n.string("Открыть управление записью")))
            .help(controller.isExpanded ? L10n.string("Свернуть управление записью") : L10n.string("Открыть управление записью"))

            if controller.isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.phase == .stopping ? L10n.string("Сохраняем запись…") : L10n.string("Идёт запись")).font(.headline)
                    Text(model.current?.title ?? model.title).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    sourceStatus(.microphone, title: L10n.string("Микрофон"), icon: "mic.fill")
                    sourceStatus(.meeting, title: L10n.string("Звук встречи"), icon: "speaker.wave.2.fill")
                }
                ScrollView {
                    LiveSalesHintView(intelligence: intelligence, compact: true)
                }.frame(maxHeight: .infinity)
                Divider()
                HStack(spacing: 8) {
                    Button(L10n.string("Открыть встречу")) { controller.showMeeting() }
                    Spacer(minLength: 0)
                    Button { Task { await model.stop() } } label: {
                        Label(L10n.string("Завершить"), systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(model.phase != .recording)
                    .help(L10n.string("Завершить запись и сохранить встречу"))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(teal.opacity(0.35)))
        .environment(\.locale, language.locale)
    }

    private func receiving(_ source: AudioSource) -> Bool {
        guard let last = model.lastSamples[source] else { return false }
        return ProcessInfo.processInfo.systemUptime - last < 2
    }

    private var equalizer: some View {
        let mic = receiving(.microphone) ? max(0, model.levels[.microphone] ?? 0) : 0
        let meeting = receiving(.meeting) ? max(0, model.levels[.meeting] ?? 0) : 0
        let levels: [Float] = [mic, meeting, max(mic, meeting), meeting, mic]
        return HStack(alignment: .center, spacing: 2) {
            ForEach(0..<levels.count, id: \.self) { index in
                Capsule().fill(teal).frame(width: 3, height: 3 + CGFloat(min(1, sqrt(levels[index]) * 4)) * 21)
            }
        }
        .frame(width: 23, height: 26)
        .animation(.easeOut(duration: 0.12), value: levels)
        .accessibilityLabel(L10n.string("Уровень звука записи"))
    }

    private func sourceStatus(_ source: AudioSource, title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).frame(width: 16)
            Text(title)
            Spacer()
            Circle().fill(receiving(source) ? teal : .orange).frame(width: 6, height: 6)
            Text(receiving(source) ? L10n.string("Подключён") : L10n.string("Нет потока")).font(.caption).foregroundStyle(.secondary)
        }.font(.caption)
    }
}
