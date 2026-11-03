import Foundation
import CopilotCore

struct PromptContextTests {
    func run() {
        let price = "Стоимость аудита 120000 рублей. Эта цена действует только при оплате после подписания договора."
        let deadline = "Срок внедрения 15 рабочих дней. При неполных исходных данных срок согласуется отдельно."
        let proposal = String(repeating: "Описание внутренней структуры справочника материалов.\n\n", count: 1800) + price
        let deal = String(repeating: "История отправки технических уведомлений.\n\n", count: 2200) + deadline
        let result = PromptContext.retrieve(proposal: proposal, deal: deal, latestUtterance: "Какая стоимость аудита и срок внедрения?", recentUtterances: [])
        precondition(result.renderedText.count <= 30_000)
        precondition(result.excerpts.contains { $0.source == "КП" && $0.text.contains(price) })
        precondition(result.excerpts.contains { $0.source == "Сделка" && $0.text.contains(deadline) })
        for source in ["КП", "Сделка"] { precondition(result.excerpts.filter { $0.source == source }.reduce(0) { $0 + $1.renderedText.count } <= 12_000) }
        let evidence = result.supportingExcerpt(quote: "Стоимость аудита 120000 рублей.", source: "КП")
        precondition(evidence?.text.contains("только при оплате после подписания договора") == true)
        precondition(result.supportingExcerpt(quote: "Стоимость аудита 999 рублей.", source: "КП") == nil)
        precondition(result.supportingExcerpt(quote: price, source: "Сделка") == nil)
        let fallback = PromptContext.retrieve(proposal: "Первый пункт.\n\nСредний пункт.\n\nПоследний пункт.", deal: "", latestUtterance: "Unmatched zebra", recentUtterances: [])
        precondition(fallback.usedFallback && fallback.excerpts.contains { $0.text == "Последний пункт." })
        let conditional = PromptContext.retrieve(proposal: "Стоимость 120000 рублей.\n\nЕсли исходные данные неполные, цена пересматривается.", deal: "", latestUtterance: "Какая стоимость?", recentUtterances: [])
        precondition(conditional.supportingExcerpt(quote: "Стоимость 120000 рублей.", source: "КП")?.text.contains("цена пересматривается") == true)
        let oversize = PromptContext.retrieve(proposal: String(repeating: "стоимость ", count: 3000), deal: "", latestUtterance: "Какая стоимость?", recentUtterances: [])
        precondition(oversize.omittedOversizedCount > 0 && oversize.excerpts.isEmpty)
        print("PASS: bounded proposal/deal retrieval, relevant tail, full conditions, provenance, fallback and oversized refusal")
    }
}
