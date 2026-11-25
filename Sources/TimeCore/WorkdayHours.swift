import Foundation

public struct WorkdayHours: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let lunch: RestPeriod?

    public init?(start: Int, end: Int, lunch: RestPeriod?) {
        guard RestPeriod(start: start, end: end).valid else { return nil }
        if let lunch {
            guard lunch.valid, start < lunch.start, lunch.end < end else { return nil }
        }
        self.start = start
        self.end = end
        self.lunch = lunch
    }

    public init?(restPeriods: [RestPeriod]) {
        let ordinary = Schedule.complement(of: restPeriods)
        switch ordinary.count {
        case 1:
            self.init(start: ordinary[0].start, end: ordinary[0].end, lunch: nil)
        case 2:
            self.init(start: ordinary[0].start, end: ordinary[1].end,
                      lunch: RestPeriod(start: ordinary[0].end, end: ordinary[1].start))
        default:
            return nil
        }
    }

    public var ordinaryPeriods: [RestPeriod] {
        guard let lunch else { return [RestPeriod(start: start, end: end)] }
        return [RestPeriod(start: start, end: lunch.start), RestPeriod(start: lunch.end, end: end)]
    }

    public var restPeriods: [RestPeriod] { Schedule.complement(of: ordinaryPeriods) }

    public static func minute(from text: String, allowEndOfDay: Bool = false) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .widthInsensitive, locale: Locale(identifier: "zh_CN"))
            .replacingOccurrences(of: ".", with: ":")
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        let hours: Substring
        let minutes: Substring
        switch parts.count {
        case 1 where (3...4).contains(value.count):
            hours = value.dropLast(2)
            minutes = value.suffix(2)
        case 1 where (1...2).contains(value.count):
            hours = value[...]
            minutes = "00"
        case 2 where (1...2).contains(parts[0].count) && parts[1].count == 2:
            hours = parts[0]
            minutes = parts[1]
        default:
            return nil
        }
        guard hours.allSatisfy({ $0.isASCII && $0.isNumber }), minutes.allSatisfy({ $0.isASCII && $0.isNumber }),
              let hour = Int(hours), let minute = Int(minutes), (0...59).contains(minute) else { return nil }
        if hour == 24 && minute == 0 && allowEndOfDay { return 1440 }
        guard (0...23).contains(hour) else { return nil }
        return hour * 60 + minute
    }
}
