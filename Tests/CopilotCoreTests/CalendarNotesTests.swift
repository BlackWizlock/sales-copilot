import Foundation
import CopilotCore

struct CalendarNotesTests {
    func run() {
        let formatted = CalendarNotes.markdown("<p><b>Цель</b></p><p>Обсудить условия<br>Без изменения цены</p><ul><li>Сроки</li><li>Оплата</li></ul>")
        precondition(formatted.contains("**Цель**") && formatted.contains("\n\nОбсудить условия"))
        precondition(formatted.contains("• Сроки") && formatted.contains("• Оплата") && !formatted.contains("<"))
        precondition(CalendarNotes.markdown("[b]Условия[/b]\n[url=https://example.com/docs]Документы[/url]").contains("[Документы](https://example.com/docs)"))
        precondition(CalendarNotes.markdown("<script>alert('bad')</script><p>Стоимость 100 000 рублей</p>") == "Стоимость 100 000 рублей")
        precondition(CalendarNotes.markdown(String(repeating: "a", count: 20_000)).count == 10_000)
        let oversized = String(repeating: "a", count: 10_001)
        do { _ = try CalendarNotes.editableMarkdown(oversized); preconditionFailure("Oversized editor input must not be silently truncated") } catch {}
        precondition((try? CalendarNotes.editableMarkdown("[b]Условия[/b]")) == "**Условия**")
        for unsafe in ["javascript:alert(1)", "file:///etc/passwd", "http://example.com", "https://key@example.com/", "https://example.com:8443/"] {
            precondition(CalendarNotes.webURL(unsafe) == nil)
        }
        precondition(CalendarNotes.webURL("https://example.com/offer") != nil)
        precondition(CalendarNotes.linkLabel(URL(string: "https://telemost.360.yandex.ru/j/123")!) == "Телемост")
        precondition(CalendarNotes.linkLabel(URL(string: "https://synthetic.bitrix24.ru/crm/deal/details/42/")!) == "Открыть сделку в Битрикс24")
        print("PASS: bounded calendar formatting, paragraphs, emphasis, lists, safe links and unchanged commercial facts")
    }
}
