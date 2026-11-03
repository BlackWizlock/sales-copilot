import Foundation

/// A bounded, local presentation of calendar notes. Never loads HTML resources.
public enum CalendarNotes {
    public static func markdown(_ source: String) -> String {
        var value = String(source.prefix(10_000)).replacingOccurrences(of: "\r\n", with: "\n")
        func replace(_ pattern: String, _ template: String) {
            value = value.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        replace("(?is)<(script|style)\\b[^>]*>.*?</\\1>", "")
        replace("(?i)<br\\s*/?>|</(?:p|div|h[1-6])>", "\n\n")
        replace("(?i)<(?:strong|b)>|\\[b\\]", "**")
        replace("(?i)</(?:strong|b)>|\\[/b\\]", "**")
        replace("(?i)<(?:em|i)>|\\[i\\]", "*")
        replace("(?i)</(?:em|i)>|\\[/i\\]", "*")
        replace("(?i)<li[^>]*>|\\[\\*\\]", "\n• ")
        replace("(?i)</li>|\\[/?list(?:=1)?\\]", "\n")
        replace("(?is)<a\\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", "[$2]($1)")
        replace("(?is)\\[url=([^\\]]+)\\](.*?)\\[/url\\]", "[$2]($1)")
        replace("(?is)\\[url\\](.*?)\\[/url\\]", "$1")
        replace("<[^>]+>", "")
        for (entity, text) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            value = value.replacingOccurrences(of: entity, with: text)
        }
        replace("\n[ \\t]+", "\n")
        replace("\n{3,}", "\n\n")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Editing must refuse oversized input rather than silently discard its tail.
    public static func editableMarkdown(_ source: String) throws -> String {
        guard source.count <= 10_000 else {
            throw NSError(domain: "CalendarNotes", code: 1, userInfo: [NSLocalizedDescriptionKey: "Описание длиннее 10 000 символов. Измените его в Битрикс24, чтобы сохранить весь текст."])
        }
        return markdown(source)
    }

    public static func webURL(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443 else { return nil }
        return parts.url
    }

    public static func linkLabel(_ url: URL) -> String {
        if MeetingLink.validated(url.absoluteString) != nil {
            return url.host?.contains("zoom") == true ? "Zoom" : "Телемост"
        }
        if url.path.hasPrefix("/crm/deal/details/") { return "Открыть сделку в Битрикс24" }
        if url.path.hasPrefix("/crm/lead/details/") { return "Открыть лид в Битрикс24" }
        return url.host ?? url.absoluteString
    }
}
