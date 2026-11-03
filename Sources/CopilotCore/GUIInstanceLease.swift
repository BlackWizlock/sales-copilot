import Foundation
import Darwin

/// A process-lifetime advisory lock; paid inference diagnostics also acquire it; read-only CLI/MCP do not.
public final class GUIInstanceLease {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }

    public static func acquire(directory: URL) throws -> GUIInstanceLease? {
        if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw CopilotError.message("Instance directory is a symbolic link")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("gui.lock").path
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), fchmod(fd, 0o600) == 0 else {
            Darwin.close(fd); throw CopilotError.message("Unsafe instance lock file")
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return GUIInstanceLease(fd) }
        let code = errno; Darwin.close(fd)
        if code == EWOULDBLOCK { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
