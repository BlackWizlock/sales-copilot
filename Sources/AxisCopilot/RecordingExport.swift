import AVFoundation
import CopilotCore

enum RecordingExport {
    static func export(session: MeetingSession, store: SessionStore) async throws {
        let composition = AVMutableComposition()
        for source in AudioSource.allCases {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            var lastEnd = 0.0
            for chunk in session.chunks.filter({ $0.source == source }).sorted(by: { $0.start < $1.start }) {
                let asset = AVURLAsset(url: try store.fileURL(session.id, filename: chunk.filename))
                guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let duration = try await asset.load(.duration)
                let at = max(lastEnd, chunk.start)
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: CMTime(seconds: at, preferredTimescale: 16000))
                lastEnd = at + duration.seconds
            }
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CopilotError.message("M4A недоступен")
        }
        let output = try store.fileURL(session.id, filename: "meeting.m4a")
        let temporary = try store.fileURL(session.id, filename: "meeting-export.m4a")
        if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
        try await exporter.export(to: temporary, as: .m4a)
        if FileManager.default.fileExists(atPath: output.path) { _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: output) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }
}
