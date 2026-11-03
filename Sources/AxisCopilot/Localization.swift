import Foundation
import SwiftUI

@MainActor final class UILanguageSettings: ObservableObject {
    static let shared = UILanguageSettings()
    @Published var selection: String {
        didSet { UserDefaults.standard.set(selection, forKey: "uiLanguage") }
    }
    init() {
        let stored = UserDefaults.standard.string(forKey: "uiLanguage") ?? "system"
        selection = ["system", "ru", "en"].contains(stored) ? stored : "system"
    }
    var locale: Locale { Locale(identifier: L10n.languageCode(selection: selection)) }
}

enum L10n {
    static func languageCode(selection: String? = nil) -> String {
        let selected = selection ?? UserDefaults.standard.string(forKey: "uiLanguage") ?? "system"
        if selected == "ru" || selected == "en" { return selected }
        return Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") == true ? "ru" : "en"
    }
    /// Use for messages assembled outside SwiftUI. Client-provided text is never translated.
    static func string(_ key: String, language: String? = nil, bundle: Bundle = .main) -> String {
        guard let path = bundle.path(forResource: language ?? languageCode(), ofType: "lproj"), let localizedBundle = Bundle(path: path) else { return key }
        return localizedBundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
    /// Localize the template only. Arguments may contain client data or external errors.
    static func format(_ key: String, _ arguments: CVarArg..., language: String? = nil, bundle: Bundle = .main) -> String {
        String(format: string(key, language: language, bundle: bundle), locale: Locale(identifier: language ?? languageCode()), arguments: arguments)
    }
    /// Translate only known messages from our Core error type. System/provider errors
    /// retain their original language and content; arbitrary client strings never enter here.
    static func error(_ error: Error) -> String {
        let text = error.localizedDescription
        guard String(reflecting: type(of: error)) == "CopilotCore.CopilotError" else { return text }
        if coreMessageKeys.contains(text) { return string(text) }
        let prefix = "Сначала подключите в настройках портал "
        let suffix = ". Ссылка не меняет подключение."
        if text.hasPrefix(prefix), text.hasSuffix(suffix) {
            let portal = String(text.dropFirst(prefix.count).dropLast(suffix.count))
            if portal.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil {
                return format("Сначала подключите в настройках портал %@. Ссылка не меняет подключение.", portal)
            }
        }
        return text
    }
    private static let coreMessageKeys: Set<String> = [
        "В документе нет распознанного текста.",
        "Выберите сделку разрешённого портала",
        "Дневной бюджет OpenRouter исчерпан",
        "Добавьте и проверьте итоги встречи",
        "Дождитесь завершения записи и транскрипции",
        "Документ слишком большой. Добавьте выдержку до 60 000 символов.",
        "Завершите запись или текущую операцию перед открытием сделки.",
        "История чата слишком велика для загрузки",
        "Можно добавить до 12 документов общим объёмом до 240 000 символов.",
        "Не удалось определить день",
        "Не удалось построить календарь",
        "Не удалось создать файл резюме",
        "Не удалось сохранить чат",
        "Неверный идентификатор встречи",
        "Недопустимая папка",
        "Недопустимая папка CRM",
        "Недопустимая папка встречи",
        "Недопустимая папка чата",
        "Недопустимая ссылка",
        "Недопустимая ссылка сделки. Нужны только разрешённый портал и положительный номер сделки.",
        "Недопустимая ссылка чата",
        "Недопустимое имя файла",
        "Недопустимый локальный файл CRM",
        "Нужен обычный M4A размером до 50 МБ. При большем размере сохраните текст без аудио явно.",
        "Облачный бюджет не задан",
        "Ожидался WAV PCM16 mono",
        "Подготовка другой сделки уже выполняется. Дождитесь её завершения.",
        "Символическая ссылка вместо папки встречи",
        "Символические ссылки не поддерживаются",
        "Событие календаря без распознаваемой даты или часового пояса",
        "Ссылка вместо папки CRM",
        "Ссылка вместо файла CRM",
        "У встречи уже другая сделка. Исходная привязка сохранена.",
        "Чат относится к другой встрече"
    ]

}

struct LocaleSettingsView: View {
    @ObservedObject private var language = UILanguageSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Язык интерфейса", selection: $language.selection) {
                Text("Как в системе").tag("system")
                Text("Русский").tag("ru")
                Text("English").tag("en")
            }
            Text("Язык интерфейса не меняет язык записи и не переводит материалы клиента.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
