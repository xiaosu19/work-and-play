import Foundation
import TimeCore
import TimeStore

enum ReportPeriod: String, CaseIterable, Identifiable {
    case day = "日"
    case week = "周"
    case month = "月"
    case year = "年"
    case all = "全部"

    var id: Self { self }

    private var component: Calendar.Component? {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        case .all: nil
        }
    }

    static var calendar: Calendar {
        var calendar = Tracker.localCalendar
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    func interval(for date: Date) -> DateInterval? {
        component.flatMap { Self.calendar.dateInterval(of: $0, for: date) }
    }

    func dayRange(for date: Date) -> ClosedRange<String> {
        let calendar = Self.calendar
        guard let interval = interval(for: date),
              let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end)
        else { return "0000-00-00"..."9999-12-31" }
        return Schedule.dayKey(interval.start, calendar: calendar)...Schedule.dayKey(lastDay, calendar: calendar)
    }

    func moving(_ date: Date, by amount: Int) -> Date {
        guard let component else { return date }
        return Self.calendar.date(byAdding: component, value: amount, to: date) ?? date
    }

    func title(for date: Date) -> String {
        let day = Self.chinese.year().month(.wide).day()
        switch self {
        case .day:
            return date.formatted(day.weekday(.wide))
        case .week:
            guard let interval = interval(for: date) else { return date.formatted(day) }
            let end = interval.end.addingTimeInterval(-1)
            let endStyle = Self.calendar.isDate(interval.start, equalTo: end, toGranularity: .year)
                ? Self.chinese.month(.wide).day() : day
            return "\(interval.start.formatted(day)) – \(end.formatted(endStyle))"
        case .month: return date.formatted(Self.chinese.year().month(.wide))
        case .year: return date.formatted(Self.chinese.year())
        case .all: return "全部记录"
        }
    }

    private static var chinese: Date.FormatStyle {
        Date.FormatStyle(locale: Locale(identifier: "zh_CN"), calendar: calendar, timeZone: calendar.timeZone)
    }

    func chartColumns(anchor: Date, totals: [ReportTotal]) -> [ChartColumn] {
        let keys = chartKeys(anchor: anchor, totals: totals)
        let prefix = self == .year ? 7 : self == .all ? 4 : 10
        let byKey = Dictionary(grouping: totals) { String($0.day.prefix(prefix)) }
        return keys.map { key in
            let amounts = (byKey[key.id] ?? []).reduce(into: [Bucket: TimeInterval]()) {
                $0[$1.bucket, default: 0] += $1.duration
            }
            return ChartColumn(id: key.id, title: key.title, amounts: amounts)
        }
    }

    private func chartKeys(anchor: Date, totals: [ReportTotal]) -> [(id: String, title: String)] {
        if self == .all {
            return Set(totals.map { String($0.day.prefix(4)) }).sorted().map { ($0, $0) }
        }
        guard let interval = interval(for: anchor) else { return [] }
        let calendar = Self.calendar
        var items: [(id: String, title: String)] = []
        var cursor = interval.start
        while cursor < interval.end {
            let day = Schedule.dayKey(cursor, calendar: calendar)
            switch self {
            case .week:
                items.append((day, cursor.formatted(Self.chinese.weekday(.abbreviated))))
            case .month:
                let number = calendar.component(.day, from: cursor)
                items.append((day, number == 1 || number.isMultiple(of: 5) ? String(number) : ""))
            case .year:
                items.append((String(day.prefix(7)), "\(calendar.component(.month, from: cursor))月"))
            default: return items
            }
            guard let next = calendar.date(byAdding: self == .year ? .month : .day, value: 1, to: cursor),
                  next > cursor else { break }
            cursor = next
        }
        return items
    }
}

struct ChartColumn: Identifiable {
    let id: String
    let title: String
    let amounts: [Bucket: TimeInterval]
    var total: TimeInterval { amounts.values.reduce(0, +) }
}
