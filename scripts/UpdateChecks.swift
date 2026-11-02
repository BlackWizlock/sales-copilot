import Foundation

@main struct UpdateChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw UpdateFailure("FAIL: " + message) }
    }
    static func main() async throws {
        try require(UpdateValidation.isNewer("1.10", than: "1.9"), "numeric versions")
        try require(!UpdateValidation.isNewer("1.0.0", than: "1"), "equal version rejected")
        try require(!UpdateValidation.isNewer("0.9", than: "1"), "downgrade rejected")
        for value in ["", "1..2", "1beta", "-1", "1.2.3.4.5", "9999999999999999999999999"] {
            do { _ = try UpdateValidation.version(value); throw UpdateFailure("FAIL: malformed version accepted") }
            catch let failure as UpdateFailure where !failure.message.hasPrefix("FAIL:") {}
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        if CommandLine.arguments.count == 3 {
            for scenario in ["signed-valid", "signed-rollback"] {
                let directory = root.appendingPathComponent(scenario)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let dest = directory.appendingPathComponent("Current.app"), stage = directory.appendingPathComponent("New.app"), backup = directory.appendingPathComponent("Previous.app")
                try fm.copyItem(at: root.appendingPathComponent("Current.app"), to: dest)
                try fm.copyItem(at: root.appendingPathComponent("New.app"), to: stage)
                try UpdateValidation.validate(stage, current: dest)
                let signer = try UpdateValidation.certificate(dest)
                do {
                    try await UpdateInstaller.replace(staged: stage, destination: dest, backup: backup, validate: { app in
                        try require(UpdateValidation.certificate(app) == signer, "signed swap signer")
                        try require(UpdateValidation.metadata(app)["CFBundleVersion"] as? String == "2", "signed swap version")
                    }, launch: { _ in
                        if scenario == "signed-rollback" { throw UpdateFailure("injected launch failure") }
                    })
                    try require(scenario == "signed-valid", "signed failure must propagate")
                } catch { try require(scenario == "signed-rollback", "signed valid succeeds") }
                try require(UpdateValidation.metadata(dest)["CFBundleVersion"] as? String == (scenario == "signed-valid" ? "2" : "1"), "signed replacement/rollback")
                try require(UpdateValidation.certificate(dest) == signer, "installed signature after replacement/rollback")
                print("PASS \(scenario)")
            }
            return
        }
        for scenario in ["valid", "validation-failure", "launch-failure", "occupied-backup"] {
            let directory = root.appendingPathComponent(scenario); try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let dest = directory.appendingPathComponent("installed"), stage = directory.appendingPathComponent("stage"), backup = directory.appendingPathComponent("backup")
            try Data("old".utf8).write(to: dest); try Data("new".utf8).write(to: stage)
            if scenario == "occupied-backup" { try Data("existing".utf8).write(to: backup) }
            var validations = 0
            do {
                try await UpdateInstaller.replace(staged: stage, destination: dest, backup: backup, validate: { _ in
                    validations += 1
                    if scenario == "validation-failure" && validations == 2 { throw UpdateFailure("injected post-swap verification failure") }
                }, launch: { _ in
                    if scenario == "launch-failure" { throw UpdateFailure("injected launch failure") }
                })
                try require(scenario == "valid", "failure must propagate")
            } catch {
                try require(scenario != "valid", "valid replacement succeeds")
            }
            let content = String(decoding: try Data(contentsOf: dest), as: UTF8.self)
            try require(content == (scenario == "valid" ? "new" : "old"), "rollback preserves installed version for \(scenario)")
            if scenario == "valid" { try require(String(decoding: Data(contentsOf: backup), as: UTF8.self) == "old", "backup retained") }
            print("PASS \(scenario)")
        }
        print("PASS version validation")
    }
}
