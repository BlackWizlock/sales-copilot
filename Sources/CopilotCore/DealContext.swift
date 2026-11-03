import Foundation

public enum BitrixPortal {
    public static func isAllowed(_ host: String) -> Bool {
        host.range(of: "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.bitrix24\\.(?:ru|com|eu|de|by|kz|uz|tr|es|it|pl|fr|in|cn|com\\.br)$", options: .regularExpression) != nil
    }
}

public enum CRMValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([CRMValue]), object([String: CRMValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([CRMValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: CRMValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var text: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(format: "%.0f", n) : String(n)
        case .bool(let b): return b ? "Y" : "N"
        case .array(let a): return a.map(\.text).joined(separator: ", ")
        case .object(let o): return o.keys.sorted().map { "\($0): \(o[$0]!.text)" }.joined(separator: "; ")
        case .null: return ""
        }
    }
    public var object: [String: CRMValue] { if case .object(let v) = self { return v }; return [:] }
    public var array: [CRMValue] { if case .array(let v) = self { return v }; return [] }
}

public enum BitrixDate {
    public static func parse(_ value: String, timezone: String? = nil) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: value) { return date }
        // Floating calendar values must have a declared zone. Never silently interpret them in the Mac's zone.
        guard let zone = timezone.flatMap(TimeZone.init(identifier:)) else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone
        f.isLenient = false
        for format in ["dd.MM.yyyy HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "dd.MM.yyyy", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let date = f.date(from: value) { return date }
        }
        return nil
    }
}

public enum MeetingLink {
    public static func validated(_ text: String) -> URL? {
        guard let u = URLComponents(string: text), u.scheme?.lowercased() == "https",
              u.user == nil, u.password == nil, u.port == nil || u.port == 443,
              let host = u.host?.lowercased(), !u.path.isEmpty else { return nil }
        let telemost = ["telemost.yandex.ru", "telemost.yandex.com", "telemost.360.yandex.ru", "telemost.360.yandex.com"].contains(host) && u.path.hasPrefix("/j/")
        let zoom = (host == "zoom.us" || host.hasSuffix(".zoom.us")) && (u.path.hasPrefix("/j/") || u.path.hasPrefix("/my/"))
        return telemost || zoom ? u.url : nil
    }
    public static func extract(from text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let url = match.url, let valid = validated(url.absoluteString) { return valid }
        }
        return nil
    }
}

public struct CalendarMeeting: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var starts: Date
    public var ends: Date?
    public var modified: Date?
    public var dealIDs: [String]
    public var joinURL: URL?
    public var timezone: String?
    public var raw: [String: CRMValue]
    /// Recurring instances share the CRM ID; views need a distinct identity for each occurrence.
    public var occurrenceID: String { "\(id):\(starts.timeIntervalSince1970)" }
    public static func decode(_ fields: [String: CRMValue]) throws -> CalendarMeeting {
        let timezone = fields["TZ_FROM"]?.text
        let start = fields["DATE_FROM"]?.text ?? ""
        func utcTimestamp(_ key: String) -> Date? {
            guard let seconds = Double(fields[key]?.text ?? ""), seconds.isFinite, seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        // calendar.event.get expands DATE_FROM/DATE_TO for each recurring occurrence,
        // while *_TS_UTC can still describe the entire series (including its 2038 end).
        // Prefer the occurrence's civil date and declared zone; timestamps are a fallback
        // for records without a usable zone, including all-day events.
        guard let starts = BitrixDate.parse(start, timezone: timezone) ?? utcTimestamp("DATE_FROM_TS_UTC"), let id = fields["ID"]?.text, !id.isEmpty else {
            throw CopilotError.message("Событие календаря без распознаваемой даты или часового пояса")
        }
        let bindings = fields["UF_CRM_CAL_EVENT"]?.array.map(\.text) ?? []
        let ids = bindings.filter { $0.hasPrefix("D_") }.map { String($0.dropFirst(2)) }
        let text = [fields["LOCATION"]?.text, fields["DESCRIPTION"]?.text, fields["NAME"]?.text].compactMap { $0 }.joined(separator: " ")
        return CalendarMeeting(id: id, title: fields["NAME"]?.text ?? "Встреча", starts: starts,
            ends: BitrixDate.parse(fields["DATE_TO"]?.text ?? "", timezone: fields["TZ_TO"]?.text ?? timezone) ?? utcTimestamp("DATE_TO_TS_UTC"),
            modified: BitrixDate.parse(fields["TIMESTAMP_X_ISO"]?.text ?? fields["TIMESTAMP_X"]?.text ?? "", timezone: timezone), dealIDs: ids,
            joinURL: MeetingLink.extract(from: text), timezone: timezone, raw: fields)
    }
}

public struct DealContext: Codable, Identifiable, Equatable, Sendable {
    public var portal: String
    public var dealID: String
    public var title: String
    public var client: String
    public var fetchedAt: Date
    public var fields: [String: CRMValue]
    public var fieldConfiguration: CRMValue
    public var activities: [[String: CRMValue]]
    public var events: [CalendarMeeting]
    public var warnings: [String]
    public var id: String { dealID }
    public init(portal: String, dealID: String, title: String, client: String = "", fetchedAt: Date = Date(), fields: [String: CRMValue] = [:], fieldConfiguration: CRMValue = .null, activities: [[String: CRMValue]] = [], events: [CalendarMeeting] = [], warnings: [String] = []) {
        self.portal = portal; self.dealID = dealID; self.title = title; self.client = client; self.fetchedAt = fetchedAt
        self.fields = fields; self.fieldConfiguration = fieldConfiguration; self.activities = activities; self.events = events; self.warnings = warnings
    }
    public var url: URL { URL(string: "https://\(portal)/crm/deal/details/\(dealID)/")! }
    public var needs: String { fields["UF_CRM_1765470175"]?.text ?? "" }
    public var proposalReferences: String { fields["UF_CRM_1765470207"]?.text ?? "" }
    public var documentReferences: String { fields["UF_CRM_1765470198"]?.text ?? "" }
    public var asPlainText: String {
        // Explicitly label raw document references. Their contents/version have not been fetched or verified.
        var text = "Снимок CRM \(fetchedAt.formatted())\nСделка №\(dealID): \(title)\nКлиент: \(client)\nПотребности: \(needs)\nКП (ссылки/ID, содержание и актуальность не проверены): \(proposalReferences)\nДокументы (ссылки/ID): \(documentReferences)\n"
        text += "Текущие дела и календарь имеют приоритет над старыми полями даты встречи.\n"
        for a in activities { text += "Дело \(a["ID"]?.text ?? ""): \(a["SUBJECT"]?.text ?? ""); \(a["START_TIME"]?.text ?? ""); завершено \(a["COMPLETED"]?.text ?? ""); изменено \(a["LAST_UPDATED"]?.text ?? ""). \(a["DESCRIPTION"]?.text ?? "")\n" }
        for e in events { text += "Календарь \(e.id): \(e.title); \(e.starts.formatted()); изменено \(e.modified?.formatted() ?? "не указано")\n" }
        text += "Поля даты/следующего контакта: \(fields["UF_CRM_69529EFCBE56B"]?.text ?? ""), \(fields["UF_CRM_1765470239"]?.text ?? ""), \(fields["UF_CRM_1765470252"]?.text ?? "")\n"
        return text + warnings.joined(separator: "\n")
    }
}
