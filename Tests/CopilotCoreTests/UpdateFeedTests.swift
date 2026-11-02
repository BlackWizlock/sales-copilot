import Foundation
import CopilotCore

struct UpdateFeedTests {
    func run() throws {
        try UpdateHTTPResponse.validate(status: 200, isManifest: true)
        func message(_ status: Int, manifest: Bool) -> String {
            do { try UpdateHTTPResponse.validate(status: status, isManifest: manifest); return "accepted" }
            catch { return error.localizedDescription }
        }
        expectEqual(message(404, manifest: true), "В канале обновлений пока нет опубликованной версии. Повторите проверку позже.")
        expectEqual(message(404, manifest: false), "Файл обновления не найден на сервере. Повторите проверку обновлений.")
        expectEqual(message(503, manifest: true), "Сервер обновлений временно недоступен. Повторите проверку позже.")
        expectThrows(try UpdateHTTPResponse.validate(status: 403, isManifest: true))
        let feed = URL(string: "https://updates.axisconsult.ru/copilot/stable.json")!
        func manifest(build: String = "10", arch: String = "arm64", os: String = "15.0", url: String = "https://updates.axisconsult.ru/copilot/10.zip") throws -> UpdateRelease {
            let json: [String: Any] = ["schema": 1, "version": "0.3.0", "build": build, "architecture": arch, "minimumOS": os, "url": url, "sha256": String(repeating: "a", count: 64), "size": 100]
            return try UpdateRelease.decode(JSONSerialization.data(withJSONObject: json), feedURL: feed)
        }
        let release = try manifest()
        expectEqual(try release.isEligible(installedBuild: "9", operatingSystem: "15.1"), true)
        expectEqual(try release.isEligible(installedBuild: "10", operatingSystem: "15.1"), false)
        expectEqual(try release.isEligible(installedBuild: "11", operatingSystem: "15.1"), false)
        expectEqual(try manifest(os: "16.0").isEligible(installedBuild: "9", operatingSystem: "15.1"), false)
        expectThrows(try manifest(build: "v10"))
        expectThrows(try manifest(arch: "x86_64"))
        expectThrows(try manifest(url: "http://updates.axisconsult.ru/a.zip"))
        expectThrows(try manifest(url: "https://other.example/a.zip"))
        expectThrows(try UpdateArchive.validateEntry(path: "../escape", mode: 0o100644, expandedSize: 1))
        expectThrows(try UpdateArchive.validateEntry(path: "/AxisCopilot.app/a", mode: 0o100644, expandedSize: 1))
        expectThrows(try UpdateArchive.validateEntry(path: "AxisCopilot.app/../a", mode: 0o100644, expandedSize: 1))
        expectThrows(try UpdateArchive.validateEntry(path: "AxisCopilot.app/link", mode: 0o120777, expandedSize: 1))
        expectThrows(try UpdateArchive.validateEntry(path: "Other.app/a", mode: 0o100644, expandedSize: 1))
        try UpdateArchive.validateEntry(path: "AxisCopilot.app/Contents/Info.plist", mode: 0o100644, expandedSize: 100)
        expectThrows(try UpdateArchive.validate(Data("not a zip".utf8)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axis-zip-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("AxisCopilot.app/Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("AxisCopilot.app/Contents/Info.plist"))
        func zip(_ name: String, extra: [String] = []) throws -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = root
            process.arguments = ["-q", "-r"] + extra + [name, "AxisCopilot.app"]
            try process.run(); process.waitUntilExit()
            expectEqual(process.terminationStatus, 0)
            return try Data(contentsOf: root.appendingPathComponent(name))
        }
        let valid = try zip("valid.zip")
        try UpdateArchive.validate(valid)
        expectThrows(try UpdateArchive.validate(valid.dropLast()))
        var mismatchedLocalName = valid
        mismatchedLocalName[30] = 90
        expectThrows(try UpdateArchive.validate(mismatchedLocalName))
        var mismatchedSize = valid
        mismatchedSize[22] = 255
        expectThrows(try UpdateArchive.validate(mismatchedSize))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("AxisCopilot.app/link").path, withDestinationPath: "../../escape")
        expectThrows(try UpdateArchive.validate(zip("linked.zip", extra: ["-y"])))
        print("PASS: update manifest eligibility, transport and real ZIP safety")
    }
}
