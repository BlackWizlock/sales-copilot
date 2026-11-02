import Foundation

public enum UpdateHTTPResponse {
    public static func validate(status: Int, isManifest: Bool) throws {
        if status == 200 { return }
        if status == 404 {
            throw UpdateFeedError(isManifest
                ? "В канале обновлений пока нет опубликованной версии. Повторите проверку позже."
                : "Файл обновления не найден на сервере. Повторите проверку обновлений.")
        }
        if (500...599).contains(status) {
            throw UpdateFeedError("Сервер обновлений временно недоступен. Повторите проверку позже.")
        }
        throw UpdateFeedError("Сервер обновлений отклонил запрос. Проверьте подключение и повторите попытку.")
    }
}

public struct UpdateFeedError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

public struct UpdateRelease: Codable, Equatable {
    public let schema: Int
    public let version: String
    public let build: String
    public let architecture: String
    public let minimumOS: String
    public let url: URL
    public let sha256: String
    public let size: Int64
    public static let maximumArchiveSize: Int64 = 2_000_000_000

    public static func secureURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil && url.fragment == nil
    }

    public static func decode(_ data: Data, feedURL: URL) throws -> Self {
        guard data.count <= 65_536, secureURL(feedURL) else { throw UpdateFeedError("Неверный адрес обновлений.") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schema == 1, value.architecture == "arm64", secureURL(value.url),
              value.url.host == feedURL.host, value.url.port == feedURL.port,
              value.sha256.count == 64, value.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              value.size > 0, value.size <= maximumArchiveSize, !value.version.isEmpty else {
            throw UpdateFeedError("Некорректное описание обновления.")
        }
        _ = try numbers(value.build); _ = try numbers(value.minimumOS)
        return value
    }

    public func isEligible(installedBuild: String, operatingSystem: String) throws -> Bool {
        try Self.numbers(installedBuild).lexicographicallyPrecedes(Self.numbers(build)) &&
            !Self.numbers(operatingSystem).lexicographicallyPrecedes(Self.numbers(minimumOS))
    }

    private static func numbers(_ value: String) throws -> [Int] {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { throw UpdateFeedError("Неверный номер сборки или macOS.") }
        let result = try parts.map { part -> Int in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else {
                throw UpdateFeedError("Неверный номер сборки или macOS.")
            }
            return n
        }
        return result + Array(repeating: 0, count: 4 - result.count)
    }
}

/// Strict ZIP subset: one app, no links, special files, duplicate paths, encryption or ZIP64.
/// Validate central and local names before invoking the system extractor.
public enum UpdateArchive {
    public static func validateEntry(path: String, mode: UInt32, expandedSize: UInt64) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        let kind = mode & 0o170000
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.unicodeScalars.contains(where: { $0.value < 32 }),
              components.first == "AxisCopilot.app", !components.contains(".."), !components.contains("."),
              !components.dropLast().contains(""), [0, 0o100000, 0o040000].contains(kind),
              expandedSize <= 4_000_000_000 else { throw UpdateFeedError("Небезопасный файл в архиве обновления.") }
    }

    public static func validate(_ data: Data) throws {
        func fail() -> UpdateFeedError { UpdateFeedError("Повреждённый или неподдерживаемый ZIP обновления.") }
        func n(_ offset: Int, _ bytes: Int) throws -> UInt64 {
            guard offset >= 0, offset <= data.count - bytes else { throw fail() }
            return (0..<bytes).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
        }
        func extras(_ start: Int, _ length: Int) throws {
            let end = start + length
            guard end <= data.count else { throw fail() }
            var offset = start
            while offset < end {
                let kind = try n(offset, 2), size = Int(try n(offset + 2, 2))
                // Other extensions can override names, link types or sizes during extraction.
                guard [0x5455, 0x7875, 0x000a].contains(kind), offset + 4 + size <= end else { throw fail() }
                offset += 4 + size
            }
            guard offset == end else { throw fail() }
        }
        guard data.count >= 22 else { throw fail() }
        var end: Int?
        for p in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try n(p, 4) == 0x06054b50, p + 22 + Int(try n(p + 20, 2)) == data.count { end = p; break }
        }
        guard let end, try n(end + 4, 2) == 0, try n(end + 6, 2) == 0,
              try n(end + 8, 2) == n(end + 10, 2) else { throw fail() }
        let count = Int(try n(end + 10, 2)), length = Int(try n(end + 12, 4))
        var p = Int(try n(end + 16, 4))
        guard count > 0, count < 65_535, p + length == end else { throw fail() }
        var seen = Set<String>(), total: UInt64 = 0
        for _ in 0..<count {
            guard try n(p, 4) == 0x02014b50, try n(p + 8, 2) & 1 == 0,
                  [0, 8].contains(try n(p + 10, 2)), try n(p + 34, 2) == 0 else { throw fail() }
            let nameSize = Int(try n(p + 28, 2)), extra = Int(try n(p + 30, 2)), comment = Int(try n(p + 32, 2))
            let local = Int(try n(p + 42, 4)), expanded = try n(p + 24, 4), compressed = try n(p + 20, 4)
            guard p + 46 + nameSize + extra + comment <= end,
                  let name = String(data: data.subdata(in: p+46..<p+46+nameSize), encoding: .utf8),
                  seen.insert(name).inserted, compressed != UInt64(UInt32.max), expanded != UInt64(UInt32.max) else { throw fail() }
            try validateEntry(path: name, mode: UInt32(try n(p + 38, 4) >> 16), expandedSize: expanded)
            guard try n(local, 4) == 0x04034b50, try n(local + 6, 2) == n(p + 8, 2),
                  try n(local + 8, 2) == n(p + 10, 2), try n(local + 26, 2) == UInt64(nameSize) else { throw fail() }
            try extras(p + 46 + nameSize, extra)
            let localExtra = Int(try n(local + 28, 2))
            let start = local + 30, body = start + nameSize + localExtra
            try extras(start + nameSize, localExtra)
            if try n(p + 8, 2) & 8 == 0 {
                guard try n(local + 18, 4) == compressed, try n(local + 22, 4) == expanded else { throw fail() }
            }
            guard body + Int(compressed) <= p, data.subdata(in: start..<start+nameSize) == data.subdata(in: p+46..<p+46+nameSize) else { throw fail() }
            total += expanded
            guard total <= 4_000_000_000 else { throw fail() }
            p += 46 + nameSize + extra + comment
        }
        guard p == end else { throw fail() }
    }
}
