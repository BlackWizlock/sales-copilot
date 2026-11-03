import Foundation

extension SessionStore {
    /// Local deletion only. CRM data already sent to a portal is never modified.
    public func deleteMeeting(_ id: UUID) throws {
        let fm = FileManager.default
        let folder = directory(id)
        for url in [root, folder] {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CopilotError.message("Недопустимая папка встречи")
            }
        }
        let crm = root.appendingPathComponent("crm", isDirectory: true)
        var sidecars: [URL] = []
        if fm.fileExists(atPath: crm.path) {
            let values = try crm.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CopilotError.message("Недопустимая папка CRM")
            }
            for suffix in ["deal", "export"] {
                let url = crm.appendingPathComponent("\(id.uuidString)-\(suffix).json")
                if fm.fileExists(atPath: url.path) {
                    let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                    guard info.isSymbolicLink != true, info.isRegularFile == true else {
                        throw CopilotError.message("Недопустимый локальный файл CRM")
                    }
                    sidecars.append(url)
                }
            }
        }
        // Revoke before removal, including partial filesystem failure.
        try MCPAccessStore(root: root).setAllowed(id, allowed: false)
        for url in sidecars { try fm.removeItem(at: url) }
        try fm.removeItem(at: folder)
    }
}
