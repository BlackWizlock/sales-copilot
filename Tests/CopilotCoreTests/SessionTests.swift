import Foundation
import CopilotCore

final class SessionTests {
    func testPCMFileHasCorrectLengthClippingAndRoundTrip() throws {
        let samples: [Float] = [-2, -1, 0, 0.5, 1, 2]
        let data = WaveFile.encode(samples, sampleRate: 16000)
        expectEqual(data.count, 44 + samples.count * 2)
        expectEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        let decoded = try WaveFile.decode(data)
        expectEqual(decoded.sampleRate, 16000)
        expectEqual(decoded.samples.count, samples.count)
        expectEqual(decoded.samples[0], -1, accuracy: 0.001)
        expectEqual(decoded.samples[3], 0.5, accuracy: 0.001)
        expectEqual(decoded.samples[5], 1, accuracy: 0.001)
    }
    func testManifestRoundTripAndInterruptedRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var session = try store.create(title: "Тестовая встреча")
        session.state = .recording
        session.chunks = [AudioChunk(source: .meeting, start: 2.5, duration: 8, filename: "meeting-0.wav")]
        try store.save(session)
        let loaded = try store.loadAll()
        expectEqual(loaded.count, 1)
        expectEqual(loaded[0].id, session.id)
        expectEqual(loaded[0].state, .interrupted)
        expectEqual(loaded[0].chunks[0].start, 2.5)
        expectEqual(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int, 0o700)
    }
    func testCannotEscapeSessionDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let session = try store.create(title: "Тест")
        expectThrows(try store.fileURL(session.id, filename: "../outside.wav"))
        expectThrows(try store.fileURL(session.id, filename: "/tmp/outside.wav"))
    }
    func testOrphanAudioChunkRecoveredAfterInterruptedWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let session = try store.create(title: "Crash recovery")
        let file = try store.fileURL(session.id, filename: "meeting-8000-orphan.wav")
        try WaveFile.encode(Array(repeating: Float(0.1), count: 16000)).write(to: file)
        let recovered = try store.loadAll()[0]
        expectEqual(recovered.chunks.count, 1)
        expectEqual(recovered.chunks[0].start, 8)
        expectEqual(recovered.chunks[0].duration, 1)
        expectEqual(recovered.chunks[0].state, .pending)
    }
    func testChunkWriteFailureReturnsAndTailCanBeRecovered() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = AudioChunkWriter(folder: root)
        expectThrows(try writer.append(Array(repeating: Float(0.2), count: 128000), source: .meeting, at: 0))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let chunks = try writer.flush()
        expectEqual(chunks.count, 1)
        expectEqual(chunks[0].duration, 8)
        expectEqual(try WaveFile.decode(Data(contentsOf: root.appendingPathComponent(chunks[0].filename))).samples.count, 128000)
    }
    func testPartialTailAndGapKeepTheirOriginalTimes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let writer = AudioChunkWriter(folder: root)
        expectEqual(try writer.append(Array(repeating: Float(0.2), count: 16000), source: .microphone, at: 2).count, 0)
        let beforeGap = try writer.append(Array(repeating: Float(0.2), count: 8000), source: .microphone, at: 6)
        expectEqual(beforeGap.count, 1)
        expectEqual(beforeGap[0].start, 2)
        expectEqual(beforeGap[0].duration, 1)
        let tail = try writer.flush()
        expectEqual(tail.count, 1)
        expectEqual(tail[0].start, 6)
        expectEqual(tail[0].duration, 0.5)
    }
    func testTruncatedWaveIsRejected() {
        expectThrows(try WaveFile.decode(Data("RIFF".utf8)))
    }
    func testBrokenMeetingDoesNotHideHistoryAndAudioCanBeRecovered() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let valid = try store.create(title: "Valid")
        let broken = try store.create(title: "Broken")
        try Data("broken".utf8).write(to: store.fileURL(broken.id, filename: "session.json"))
        try WaveFile.encode(Array(repeating: Float(0.1), count: 16000)).write(to: store.fileURL(broken.id, filename: "meeting-4000-good.wav"))
        try Data("bad WAV".utf8).write(to: store.fileURL(valid.id, filename: "meeting-8000-bad.wav"))
        let empty = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let loaded = try store.loadAll()
        expectEqual(loaded.count, 2)
        expectEqual(loaded.first { $0.id == valid.id }?.title, "Valid")
        expectEqual(loaded.first { $0.id == broken.id }?.chunks.first?.start, 4)
    }
}
