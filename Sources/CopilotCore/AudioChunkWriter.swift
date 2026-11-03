import Foundation

/// Confined to the caller's serial audio queue. A failed write leaves samples available for retry.
public final class AudioChunkWriter {
    public var onChunk: ((AudioChunk) -> Void)?
    public private(set) var written: [AudioChunk] = []
    private let folder: URL
    private var buffers: [AudioSource: [Float]] = [:]
    private var starts: [AudioSource: Double] = [:]
    private let rate = 16000
    private let chunkSamples = 128000

    public init(folder: URL) { self.folder = folder }

    @discardableResult public func append(_ samples: [Float], source: AudioSource, at time: Double) throws -> [AudioChunk] {
        let previous = written.count
        if let start = starts[source], let buffer = buffers[source], !buffer.isEmpty,
           abs(time - (start + Double(buffer.count) / Double(rate))) > 0.25 {
            try flush(source)
        }
        if buffers[source, default: []].isEmpty { starts[source] = time }
        buffers[source, default: []].append(contentsOf: samples)
        while buffers[source, default: []].count >= chunkSamples { try flush(source, count: chunkSamples) }
        return Array(written.dropFirst(previous))
    }

    @discardableResult public func flush() throws -> [AudioChunk] {
        let previous = written.count
        var failure: Error?
        for source in AudioSource.allCases {
            do { try flush(source) } catch { failure = error }
        }
        if let failure { throw failure }
        return Array(written.dropFirst(previous))
    }

    private func flush(_ source: AudioSource, count: Int? = nil) throws {
        guard let buffer = buffers[source], !buffer.isEmpty else { return }
        let amount = min(count ?? buffer.count, buffer.count)
        let samples = Array(buffer.prefix(amount))
        let start = starts[source] ?? 0
        let filename = "\(source.rawValue)-\(Int((start * 1000).rounded()))-\(UUID().uuidString).wav"
        let url = folder.appendingPathComponent(filename)
        try WaveFile.encode(samples).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
        let chunk = AudioChunk(source: source, start: start, duration: Double(amount) / Double(rate), filename: filename, rms: rms)
        buffers[source] = Array(buffer.dropFirst(amount))
        starts[source] = start + Double(amount) / Double(rate)
        written.append(chunk)
        onChunk?(chunk)
    }
}
