import Foundation
import CopilotCore

struct ASRCatalogTests {
    func run() throws {
        expectEqual(ASRCatalog.models.count, 4)
        expectEqual(ASRCatalog.models.allSatisfy { $0.languages.contains("ru") }, true)
        expectEqual(ASRCatalog.models.first { $0.id == "parakeet-v3" }?.engine, .parakeet)
        let info = Data("{\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}".utf8)
        expectEqual(try ASRCatalog.revision(from: info), String(repeating: "a", count: 40))
        expectThrows(try ASRCatalog.revision(from: Data("{\"sha\":\"main\"}".utf8)))
        let whisper = ASRCatalog.models.first!
        let valid = Data("[{\"type\":\"file\",\"path\":\"ggml-small.bin\",\"size\":100,\"oid\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"lfs\":{\"oid\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"size\":100}}]".utf8)
        let files = try ASRCatalog.artifacts(from: valid, model: whisper, revision: String(repeating: "a", count: 40))
        expectEqual(files.count, 1)
        expectEqual(files[0].checksum, String(repeating: "b", count: 64))
        expectEqual(files[0].url.scheme, "https")
        expectEqual(files[0].url.path, "/ggerganov/whisper.cpp/resolve/" + String(repeating: "a", count: 40) + "/ggml-small.bin")
        let invalidDigest = Data(String(data: valid, encoding: .utf8)!.replacingOccurrences(of: String(repeating: "b", count: 64), with: "bad").utf8)
        expectThrows(try ASRCatalog.artifacts(from: invalidDigest, model: whisper, revision: String(repeating: "a", count: 40)))
        expectThrows(try ASRCatalog.artifacts(from: valid, model: ASRCatalog.models.last!, revision: String(repeating: "a", count: 40)))
        expectThrows(try ASRCatalog.safePath("../escape"))
        expectThrows(try ASRCatalog.safePath("/absolute"))
        expectThrows(try ASRCatalog.safePath("Encoder.mlmodelc/../escape"))
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("axis-model-delete-test-" + UUID().uuidString)
        let owned = root.appendingPathComponent(whisper.id)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let weights = owned.appendingPathComponent(whisper.filename!)
        try Data("fixture".utf8).write(to: weights)
        expectEqual(try ASRCatalog.removableDirectory(model: whisper, installed: weights, root: root, selectedID: "parakeet-v3", busy: false).path, owned.path)
        expectThrows(try ASRCatalog.removableDirectory(model: whisper, installed: weights, root: root, selectedID: whisper.id, busy: false))
        expectThrows(try ASRCatalog.removableDirectory(model: whisper, installed: weights, root: root, selectedID: "parakeet-v3", busy: true))
        expectThrows(try ASRCatalog.removableDirectory(model: whisper, installed: root.appendingPathComponent("Bundled/ggml-small.bin"), root: root, selectedID: "parakeet-v3", busy: false))
        let link = owned.appendingPathComponent("unexpected-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.path)
        expectThrows(try ASRCatalog.removableDirectory(model: whisper, installed: weights, root: root, selectedID: "parakeet-v3", busy: false))
        try FileManager.default.removeItem(at: link)
        let linkedRoot = root.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(atPath: linkedRoot.path, withDestinationPath: root.path)
        expectThrows(try ASRCatalog.removableDirectory(model: whisper, installed: linkedRoot.appendingPathComponent(whisper.id).appendingPathComponent(whisper.filename!), root: linkedRoot, selectedID: "parakeet-v3", busy: false))
        print("PASS: local ASR catalog, integrity metadata and safe inactive-owned model removal")
    }
}
