import AppKit
import CopilotCore

/// Exercises real panel lifecycle without capturing microphone or meeting audio.
@MainActor enum RecordingHUDVerification {
    static func run() async throws {
        _ = NSApplication.shared
        let model = MeetingModel()
        let controller = RecordingHUDController(model: model)
        let main = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.orderFront(nil)
        controller.attach(mainWindow: main)
        model.phase = .starting
        await Task.yield()
        guard !controller.isVisible, main.isVisible else { throw CopilotError.message("HUD hid main window before successful capture") }
        model.phase = .idle // A denied permission or failed start must leave the error visible.
        await Task.yield()
        guard !controller.isVisible, main.isVisible else { throw CopilotError.message("Failed start hid its error window") }
        model.phase = .recording
        await Task.yield()
        guard controller.isVisible, !main.isVisible else { throw CopilotError.message("Recording did not enter compact mode") }
        controller.setExpanded(true)
        guard controller.isExpanded else { throw CopilotError.message("Recording controls did not expand") }
        controller.showMeeting()
        guard main.isVisible, controller.isVisible else { throw CopilotError.message("Cannot return to meeting during capture") }
        model.phase = .stopping
        await Task.yield()
        guard controller.isVisible else { throw CopilotError.message("Saving lost recording status") }
        model.phase = .idle
        await Task.yield()
        guard !controller.isVisible, main.isVisible else { throw CopilotError.message("Recording completion did not restore meeting") }
        model.phase = .recording
        await Task.yield()
        model.error = "Synthetic capture interruption"
        model.phase = .idle
        await Task.yield()
        guard !controller.isVisible, main.isVisible else { throw CopilotError.message("Capture interruption hid error window") }
        main.close()
        print("PASS: floating recording panel, start/stop lifecycle, expansion and meeting restoration; no audio capture")
    }
}
