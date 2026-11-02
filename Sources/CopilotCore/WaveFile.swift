import Foundation

public enum WaveFile {
    public static func encode(_ samples: [Float], sampleRate: Int = 16000) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + samples.count * 2)); text("WAVEfmt ")
        u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        text("data"); u32(UInt32(samples.count * 2))
        for sample in samples {
            let clipped = sample.isFinite ? max(-1, min(1, sample)) : 0
            u16(UInt16(bitPattern: Int16((clipped * 32767).rounded())))
        }
        return data
    }
    public static func decode(_ data: Data) throws -> (samples: [Float], sampleRate: Int) {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at+1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at+2) << 16 }
        guard bytes.count >= 44, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE",
              String(bytes: bytes[12..<16], encoding: .ascii) == "fmt ", u32(16) == 16,
              u16(20) == 1, u16(22) == 1, u16(34) == 16,
              String(bytes: bytes[36..<40], encoding: .ascii) == "data",
              u32(40) <= bytes.count - 44, u32(40) % 2 == 0 else {
            throw CopilotError.message("Ожидался WAV PCM16 mono")
        }
        let samples = stride(from: 44, to: 44 + u32(40), by: 2).map { Float(Int16(bitPattern: UInt16(u16($0)))) / 32767 }
        return (samples, u32(24))
    }
}
