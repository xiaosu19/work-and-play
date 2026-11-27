import Foundation
import TimeCore

public struct RecordedSegment: Codable, Equatable {
    public let segmentID: Int64
    public let start: String
    public let end: String
    public let timeZone: String
    public let seconds: TimeInterval
    public let app: String
    public let domain: String?
    public let kind: ActivityKind
    public let bucket: Bucket
    public let classificationBasis: ClassificationBasis

    init(_ entry: ReportEntry) {
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        segmentID = entry.id
        start = entry.start.formatted(format)
        end = entry.end.formatted(format)
        timeZone = entry.timeZoneID
        seconds = entry.duration
        app = entry.appName
        domain = entry.host
        kind = entry.kind
        bucket = entry.bucket
        classificationBasis = entry.basis
    }
}

public struct WorkOperationRange: Codable {
    public let schemaVersion: Int
    public let channel: ReportChannel
    public let period: DigestPeriod
    public let regularSeconds: Int
    public let overtimeSeconds: Int
    public let workSeconds: Int
    public let days: [WorkReportInput]

    init(period: DigestPeriod, days: [WorkReportInput]) {
        schemaVersion = 1
        channel = .work
        self.period = period
        var regular: TimeInterval = 0
        var overtime: TimeInterval = 0
        for day in days {
            for segment in day.segments ?? [] {
                if segment.bucket == .regular { regular += segment.seconds }
                if segment.bucket == .overtime { overtime += segment.seconds }
            }
        }
        regularSeconds = Int(regular.rounded())
        overtimeSeconds = Int(overtime.rounded())
        workSeconds = regularSeconds + overtimeSeconds
        self.days = days
    }
}

public enum OperationJSON {
    public static var directory: URL {
        WorkReportShare.dataDirectory.appendingPathComponent("operation-json", isDirectory: true)
    }

    public static func folder(for channel: ReportChannel, in root: URL = directory) -> URL {
        root.appendingPathComponent(channel.rawValue, isDirectory: true)
    }

    static func write(_ work: WorkReportInput, _ leisure: LeisureReportInput, in root: URL) throws {
        let day = work.period.startDay
        guard work.channel == .work, leisure.channel == .leisure,
              DigestPeriod(.day, including: day) == work.period, work.period == leisure.period else {
            throw WorkReportShare.ShareError.invalidDay
        }
        let workData = try WorkReportShare.json(work)
        let leisureData = try WorkReportShare.json(leisure)
        try WorkReportShare.writePrivate(leisureData, to: location(.leisure, day, in: root))
        try WorkReportShare.writePrivate(workData, to: location(.work, day, in: root))
    }

    public static func remove(_ day: String, channels: [ReportChannel], in root: URL = directory) throws {
        guard DigestPeriod(.day, including: day) != nil else { throw WorkReportShare.ShareError.invalidDay }
        for channel in channels {
            try WorkReportShare.removePrivate(location(channel, day, in: root))
        }
    }

    public static func readWork(_ period: DigestPeriod, in root: URL = directory) throws -> WorkOperationRange {
        guard DigestPeriod(period.cadence, including: period.startDay) == period else {
            throw WorkReportShare.ShareError.invalidDay
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withFullDate]
        format.timeZone = TimeZone(secondsFromGMT: 0)
        guard let first = format.date(from: period.startDay) else { throw WorkReportShare.ShareError.invalidDay }
        let count = period.cadence == .week ? 7 : 1
        var reports: [WorkReportInput] = []
        for offset in 0..<count {
            let day = format.string(from: first.addingTimeInterval(Double(offset) * 86_400))
            do {
                let (data, _) = try WorkReportShare.readPrivate(location(.work, day, in: root))
                let report = try decoder.decode(WorkReportInput.self, from: data)
                guard report.channel == .work, report.period == DigestPeriod(.day, including: day),
                      report.schemaVersion == 1, let segments = report.segments,
                      segments.allSatisfy({ $0.bucket == .regular || $0.bucket == .overtime }) else {
                    throw WorkReportShare.ShareError.invalidDocument
                }
                reports.append(report)
            } catch WorkReportShare.ShareError.unavailable {
                continue
            }
        }
        guard !reports.isEmpty else { throw WorkReportShare.ShareError.unavailable }
        return WorkOperationRange(period: period, days: reports)
    }

    private static func location(_ channel: ReportChannel, _ day: String, in root: URL) -> URL {
        folder(for: channel, in: root).appendingPathComponent(day + ".json")
    }
}
