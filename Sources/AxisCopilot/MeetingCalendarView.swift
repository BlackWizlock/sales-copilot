import SwiftUI
import CopilotCore

@MainActor private final class MeetingCalendarState: ObservableObject {
    @Published var month = Date()
    @Published var selectedDay = Date()
    @Published var showingDay = false
    @Published var editingEvent: CalendarMeeting?
    var requestedRange: Date?
}

struct MeetingCalendarView: View {
    @ObservedObject var controller: CRMController
    var onSelectDeal: (String) -> Void
    var onConnect: () -> Void = {}
    @ObservedObject private var language = UILanguageSettings.shared
    @StateObject private var ui = MeetingCalendarState()
    private var calendar: Calendar {
        var value = Calendar.current
        value.locale = language.locale
        if language.locale.language.languageCode?.identifier == "ru" { value.firstWeekday = 2 }
        return value
    }
    private var grid: CalendarMonthGrid? { try? CalendarMonthGrid(displaying: ui.month, calendar: calendar) }
    private var monthTitle: String { ui.month.formatted(.dateTime.month(.wide).year().locale(language.locale)) }
    private func events(on day: Date) -> [CalendarMeeting] {
        guard let grid else { return [] }
        return controller.meetings.filter { (try? grid.contains($0, on: day)) == true }.sorted { $0.starts < $1.starts }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(L10n.string("Календарь встреч")).font(.title2.bold())
                    Spacer()
                    if controller.busy { ProgressView().controlSize(.small) }
                    Button { Task { await reload(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .help(L10n.string("Обновить календарь")).accessibilityLabel(Text(L10n.string("Обновить календарь")))
                        .disabled(controller.busy || !controller.connected)
                }
                if !controller.connected {
                    Text(L10n.string("Подключите личный вебхук в «Настройки» → «Битрикс24», чтобы увидеть календарь своего пользователя."))
                    Button(L10n.string("Открыть настройки Битрикс24"), action: onConnect)
                }
                if let grid {
                    HStack {
                        Text(monthTitle.capitalized(with: language.locale)).font(.title3.bold())
                        Spacer()
                        Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel(Text(L10n.string("Предыдущий месяц")))
                        Button(L10n.string("Сегодня")) { ui.month = Date(); ui.selectedDay = Date() }
                        Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
                            .accessibilityLabel(Text(L10n.string("Следующий месяц")))
                    }.disabled(controller.busy)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                        ForEach(grid.weekdays, id: \.self) { weekday in
                            Text(calendar.shortStandaloneWeekdaySymbols[weekday - 1].uppercased(with: language.locale))
                                .font(.caption.bold()).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                        ForEach(grid.days, id: \.self) { day in dayCell(day, grid: grid) }
                    }
                    Text(L10n.format("Время в часовом поясе Mac: %@. Открытие ссылки не начинает запись.", String(describing: TimeZone.current.identifier)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = controller.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(20)
        }
        .sheet(isPresented: $ui.showingDay) { dayProperties }
        .task(id: grid?.range.start) { await controller.restoreConnection(); await reload() }
        .onChange(of: controller.connected) { _, connected in
            ui.requestedRange = nil
            if connected { Task { await reload() } }
        }
        .onChange(of: controller.busy) { _, busy in if !busy { Task { await reload() } } }
        // A calendar refresh skipped during another CRM request is retried when it ends.
    }
    private func moveMonth(_ offset: Int) {
        guard let month = calendar.date(byAdding: .month, value: offset, to: grid?.monthStart ?? ui.month) else { return }
        ui.month = month; ui.selectedDay = month
    }
    private func reload(force: Bool = false) async {
        guard controller.connected, !controller.busy, let grid,
              force || ui.requestedRange != grid.range.start else { return }
        ui.requestedRange = grid.range.start
        await controller.refreshCalendar(from: grid.range.start, to: grid.range.end)
    }
    private func dayCell(_ day: Date, grid: CalendarMonthGrid) -> some View {
        let values = events(on: day)
        let selected = calendar.isDate(day, inSameDayAs: ui.selectedDay)
        let inMonth = calendar.isDate(day, equalTo: grid.monthStart, toGranularity: .month)
        return Button { ui.selectedDay = day; ui.showingDay = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(String(calendar.component(.day, from: day))).font(.body.weight(calendar.isDateInToday(day) ? .bold : .regular))
                    Spacer(minLength: 0)
                    if calendar.isDateInToday(day) { Image(systemName: "circle.fill").font(.system(size: 5)).accessibilityHidden(true) }
                }
                ForEach(Array(values.prefix(2)), id: \.occurrenceID) { event in
                    Text(event.title).font(.system(size: 10)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                if values.count > 2 { Text("+\(values.count - 2)").font(.caption2) }
                Spacer(minLength: 0)
            }
            .padding(7).frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .foregroundStyle(inMonth ? Color.primary : Color.secondary)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(inMonth ? 0.07 : 0.03))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        }.buttonStyle(.plain)
            .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(language.locale)) + ", " + String(values.count) + " " + L10n.string("встреч"))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var dayProperties: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Text(ui.selectedDay.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(language.locale)))
                    .font(.title2.bold()).textSelection(.enabled)
                Spacer()
                Button(L10n.string("Закрыть")) { ui.showingDay = false }.keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let selectedEvents = events(on: ui.selectedDay)
                    if selectedEvents.isEmpty {
                        Text(L10n.string("На этот день встреч нет")).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(selectedEvents, id: \.occurrenceID) { event in eventRow(event) }
                }
            }
            Text(L10n.format("Время в часовом поясе Mac: %@. Открытие ссылки не начинает запись.", String(describing: TimeZone.current.identifier)))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 680, height: 560)
            .task(id: ui.selectedDay) { await controller.loadCalendarDeals(events(on: ui.selectedDay).flatMap(\.dealIDs)) }
            .sheet(item: $ui.editingEvent) { event in CalendarDescriptionEditor(event: event, controller: controller) }
    }
    private func eventRow(_ event: CalendarMeeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(event.title).font(.headline)
            if event.raw["DT_SKIP_TIME"]?.text == "Y" {
                Text(L10n.string("Весь день")).font(.callout)
            } else {
                Text(event.starts.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(language.locale)) +
                     (event.ends.map { " – " + $0.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(language.locale)) } ?? ""))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let location = event.raw["LOCATION"]?.text, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(String(location.prefix(2_000)), systemImage: "mappin.and.ellipse")
                    .font(.callout).textSelection(.enabled)
            }
            if let description = event.raw["DESCRIPTION"]?.text, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CalendarNotesView(source: description).padding(.vertical, 6)
            }
            HStack {
                if event.joinURL != nil { Button(L10n.string("Войти в Телемост / Zoom")) { controller.join(event) } }
                Spacer()
                Button(L10n.string("Изменить описание")) { ui.editingEvent = event }.disabled(controller.busy)
            }
            ForEach(event.dealIDs, id: \.self) { id in
                Divider().padding(.vertical, 4)
                if let deal = controller.calendarDeals[id] {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(deal.title).font(.headline).textSelection(.enabled)
                        if !deal.client.isEmpty { Text(deal.client).font(.callout).foregroundStyle(.secondary) }
                        HStack {
                            Link(L10n.string("Открыть сделку в Битрикс24"), destination: deal.url)
                            Spacer()
                            Button(L10n.string("Подготовить встречу")) { ui.showingDay = false; onSelectDeal(id) }.disabled(controller.busy)
                        }
                        Text(L10n.string("Создаст черновик в Copilot с контекстом этой сделки. Запись начнёте кнопкой «Слушать». Битрикс24 не изменится."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if let error = controller.calendarDealErrors[id] {
                    Text(L10n.string("Не удалось загрузить название связанной сделки")).font(.callout)
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.string("Повторить загрузку сделки")) { Task { await controller.loadCalendarDeals([id]) } }
                } else {
                    ProgressView(L10n.string("Загружаем связанную сделку…")).controlSize(.small)
                }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
