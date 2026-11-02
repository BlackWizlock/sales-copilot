import Foundation

@main struct BitrixKeychainChecks {
    static func main() throws {
        // A fresh namespace prevents any read, overwrite or deletion of real application credentials.
        let service = "ru.axisconsult.copilot.synthetic-tests." + UUID().uuidString
        let account = "synthetic-account"
        defer { try? BitrixCredentials.remove(service: service, account: account) }
        let empty = try BitrixCredentials.load(service: service, account: account)
        precondition(empty == nil)
        let first = try BitrixCredentials(webhook: "https://synthetic-first.bitrix24.ru/rest/7/synthetic-first/")
        try first.save(service: service, account: account)
        let loaded = try BitrixCredentials.load(service: service, account: account)
        precondition(loaded?.portal == first.portal && loaded?.userID == first.userID && loaded?.secret == first.secret)
        let second = try BitrixCredentials(webhook: "https://synthetic-second.bitrix24.com/rest/9/synthetic-second/")
        try second.save(service: service, account: account)
        let changed = try BitrixCredentials.load(service: service, account: account)
        precondition(changed?.portal == second.portal && changed?.secret == second.secret)
        try BitrixCredentials.remove(service: service, account: account)
        let removed = try BitrixCredentials.load(service: service, account: account)
        precondition(removed == nil)
        print("PASS: isolated synthetic Keychain create/read/update/delete; real application credentials untouched")
    }
}
