import Foundation

@main struct KeychainQuietChecks {
    static func main() throws {
        let service = CommandLine.arguments.last!
        precondition(service.hasPrefix("ru.axisconsult.copilot.quiet-test."))
        #if KEYCHAIN_FIXTURE_WRITER
        if CommandLine.arguments.contains("--delete") { try BitrixCredentials.remove(service: service, account: "fixture"); return }
        let value = try BitrixCredentials(webhook: "https://synthetic.bitrix24.ru/rest/7/synthetic-only/")
        try value.save(service: service, account: "fixture")
        #else
        let start = Date()
        do { _ = try BitrixCredentials.load(service: service, account: "fixture"); preconditionFailure("Foreign identity must not read owner-protected key") }
        catch { precondition(Date().timeIntervalSince(start) < 2, "Silent read must fail promptly without an ACL dialog") }
        print("PASS: foreign-build Keychain ACL refuses access silently; no interactive unlock, credential mutation or real-key access")
        #endif
    }
}
