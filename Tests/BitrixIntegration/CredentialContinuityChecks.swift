import Foundation
import CopilotCore

@main struct CredentialContinuityChecks {
    static func main() throws {
        let mode = CommandLine.arguments[1], service = CommandLine.arguments[2]
        precondition(service.hasPrefix("ru.axisconsult.copilot.continuity-test."))
        #if BUILD_B
        let build = "B"
        #else
        let build = "A"
        #endif
        #if CREDENTIAL_BRIDGE
        let bridge = CredentialBridge(directory: URL(fileURLWithPath: CommandLine.arguments[4]),
            bundledHelper: URL(fileURLWithPath: CommandLine.arguments[3]))
        if mode == "foreign" || mode == "tampered" {
            do { _ = try bridge.perform(.read, domain: .bitrix); throw CopilotError.message("FAIL: unauthorized credential read") }
            catch is CredentialFailure { print("PASS: denied " + mode); return }
        }
        if mode == "cleanup" {
            _ = try bridge.perform(.purge, domain: .bitrix)
            _ = try bridge.perform(.purge, domain: .openrouter)
        } else if mode == "migration" {
            _ = try bridge.perform(.purge, domain: .openrouter)
            let interrupted = try CredentialVault.read(.openrouter, bridge: bridge) {
                try CredentialVault.remove(.openrouter, bridge: bridge)
                return Data("stale-synthetic".utf8)
            }
            precondition(interrupted == nil, "Concurrent removal must prevent stale migration")
            _ = try bridge.perform(.purge, domain: .openrouter)
            let replaced = try CredentialVault.read(.openrouter, bridge: bridge) {
                try CredentialVault.save(Data("new-synthetic".utf8), domain: .openrouter, bridge: bridge)
                return Data("stale-synthetic".utf8)
            }
            precondition(replaced == Data("new-synthetic".utf8), "Concurrent save must outrank stale migration")
            _ = try bridge.perform(.purge, domain: .openrouter)
            var legacyCalls = 0
            let first = try CredentialVault.read(.openrouter, bridge: bridge) { legacyCalls += 1; return Data("legacy-synthetic".utf8) }
            precondition(first == Data("legacy-synthetic".utf8) && legacyCalls == 1)
            let second = try CredentialVault.read(.openrouter, bridge: bridge) { throw CredentialFailure.protocolMismatch }
            precondition(second == first)
            try CredentialVault.remove(.openrouter, bridge: bridge)
            let deleted = try CredentialVault.read(.openrouter, bridge: bridge) { throw CredentialFailure.protocolMismatch }
            precondition(deleted == nil, "Tombstone must suppress legacy fallback")
            _ = try bridge.perform(.write, domain: .openrouter, data: first)
            _ = try bridge.perform(.corrupt, domain: .openrouter)
            do {
                _ = try CredentialVault.read(.openrouter, bridge: bridge) { legacyCalls += 1; return first }
                throw CopilotError.message("FAIL: corrupted storage accepted")
            } catch is CredentialFailure { precondition(legacyCalls == 1, "Error must not trigger legacy fallback") }
            _ = try bridge.perform(.purge, domain: .openrouter)
            do { _ = try bridge.perform(.write, domain: .openrouter, data: Data(repeating: 1, count: 8193)); throw CopilotError.message("FAIL: oversized key accepted") }
            catch CredentialFailure.size { }
        } else if mode == "purge" {
            _ = try bridge.perform(.purge, domain: .bitrix)
        } else if mode == "write" {
            _ = try bridge.perform(.write, domain: .bitrix, data: Data("synthetic-only".utf8))
        } else if mode == "delete" {
            _ = try bridge.perform(.delete, domain: .bitrix)
            let saved = try bridge.perform(.read, domain: .bitrix)
            precondition(saved.present && saved.deleted && saved.data == nil, "Deletion must not resurrect a legacy value")
        } else {
            let saved = try bridge.perform(.read, domain: .bitrix)
            precondition(saved.present && !saved.deleted && saved.data == Data("synthetic-only".utf8))
        }
        #else
        if mode == "write" {
            try BitrixCredentials(webhook: "https://synthetic.bitrix24.ru/rest/7/synthetic-only/").save(service: service, account: "fixture")
        } else if mode == "delete" {
            try BitrixCredentials.remove(service: service, account: "fixture")
        } else {
            let saved = try BitrixCredentials.load(service: service, account: "fixture", allowInteraction: false)
            guard saved?.portal == "synthetic.bitrix24.ru", saved?.secret == "synthetic-only" else {
                throw CopilotError.message("FAIL: signed update lost synthetic credential access")
            }
        }
        #endif
        print("PASS: credential continuity build " + build + " " + mode)
    }
}
