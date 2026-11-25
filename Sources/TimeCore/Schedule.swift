import Foundation

public struct RestPeriod: Equatable, Codable, Sendable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public var valid: Bool { start >= 0 && start < end && end <= 1440 }

    public var description: String { "\(Self.format(start))–\(Self.format(end))" }

    public static func format(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

public struct Schedule: Equatable, Codable, Sendable {
    /// Gregorian weekday numbering. Sunday is 1.
    public var weekdays: [Int: [RestPeriod]]
    /// An empty array explicitly clears this day's rest periods.
    public var overrides: [String: [RestPeriod]]

    public init(weekdays: [Int: [RestPeriod]] = [:], overrides: [String: [RestPeriod]] = [:]) {
        self.weekdays = weekdays
        self.overrides = overrides
    }

    public static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func normalized(_ periods: [RestPeriod]) -> [RestPeriod] {
        var result: [RestPeriod] = []
        for period in periods.filter(\.valid).sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.end >= period.start {
                result[result.count - 1] = RestPeriod(start: last.start, end: max(last.end, period.end))
            } else {
                result.append(period)
            }
        }
        return result
    }

    public static func complement(of periods: [RestPeriod]) -> [RestPeriod] {
        var cursor = 0
        var result: [RestPeriod] = []
        for period in normalized(periods) {
            if cursor < period.start {
                result.append(RestPeriod(start: cursor, end: period.start))
            }
            cursor = period.end
        }
        if cursor < 1440 { result.append(RestPeriod(start: cursor, end: 1440)) }
        return result
    }

    public struct DayPlan: Equatable, Sendable {
        public let periods: [RestPeriod]
        public let isOverride: Bool
    }

    public func plan(for date: Date, calendar: Calendar) -> DayPlan {
        let override = overrides[Self.dayKey(date, calendar: calendar)]
        let weekly = weekdays[calendar.component(.weekday, from: date)] ?? []
        return DayPlan(periods: Self.normalized(override ?? weekly), isOverride: override != nil)
    }

    public func activeRestPeriod(at date: Date, calendar: Calendar) -> RestPeriod? {
        guard let span = calendar.dateInterval(of: .day, for: date) else { return nil }
        return windows(on: span, plan: plan(for: date, calendar: calendar), calendar: calendar)
            .first { $0.range.contains(date) }?.period
    }

    public func activeBucket(for category: ActivityCategory, at date: Date, calendar: Calendar) -> Bucket? {
        Bucket.forCategory(category, restReason: activeRestPeriod(at: date, calendar: calendar)?.description)
    }

    func split(_ interval: DateInterval, calendar: Calendar) -> [ScheduledRange] {
        var result: [ScheduledRange] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end,
              let nextDay = calendar.dateInterval(of: .day, for: day)?.end, nextDay > day {
            let key = Self.dayKey(day, calendar: calendar)
            let plan = plan(for: day, calendar: calendar)
            let windows = windows(on: DateInterval(start: day, end: nextDay), plan: plan, calendar: calendar)
            let source = plan.isOverride ? "日期覆盖" : "周排班"
            var cursor = max(day, interval.start)
            let end = min(nextDay, interval.end)
            for window in windows {
                let start = max(cursor, window.range.lowerBound)
                let stop = min(end, window.range.upperBound)
                guard start < stop else { continue }
                if cursor < start {
                    result.append(ScheduledRange(start: cursor, end: start, day: key, restReason: nil))
                }
                result.append(ScheduledRange(start: start, end: stop, day: key,
                                             restReason: "\(source) \(window.period.description)"))
                cursor = stop
            }
            if cursor < end {
                result.append(ScheduledRange(start: cursor, end: end, day: key, restReason: nil))
            }
            day = nextDay
        }
        return result
    }

    private func windows(on day: DateInterval, plan: DayPlan, calendar: Calendar)
        -> [(range: Range<Date>, period: RestPeriod)] {
        plan.periods.compactMap { period in
            let start = boundary(period.start, day: day.start, nextDay: day.end, calendar: calendar)
            let end = boundary(period.end, day: day.start, nextDay: day.end, calendar: calendar)
            guard start < end else { return nil }
            return (start..<end, period)
        }
    }

    private func boundary(_ minute: Int, day: Date, nextDay: Date, calendar: Calendar) -> Date {
        if minute == 0 { return day }
        if minute == 1440 { return nextDay }
        let localTime = DateComponents(hour: minute / 60, minute: minute % 60, second: 0)
        return min(nextDay, calendar.nextDate(after: day.addingTimeInterval(-1), matching: localTime,
                                             matchingPolicy: .nextTime, repeatedTimePolicy: .first) ?? nextDay)
    }
}

struct ScheduledRange {
    let start: Date
    let end: Date
    let day: String
    let restReason: String?
}
