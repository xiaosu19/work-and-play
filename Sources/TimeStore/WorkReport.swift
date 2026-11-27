import Darwin
import Foundation
import TimeCore

public enum ReportChannel: String, Codable, CaseIterable, Identifiable {
    case work, leisure
    public var id: Self { self }
}

public enum ReportCadence: String, Codable, CaseIterable, Identifiable {
    case day, week
    public var id: Self { self }
}

public struct DigestPeriod: Codable, Equatable {
    public let cadence: ReportCadence
    public let startDay: String
    public let endDay: String
    public var days: ClosedRange<String> { startDay...endDay }

    public init?(_ cadence: ReportCadence, including day: String) {
        let parts = day.split(separator: "-")
        guard day.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
              parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        guard let date = calendar.date(from: DateComponents(year: Int(parts[0]), month: Int(parts[1]), day: Int(parts[2]))),
              Schedule.dayKey(date, calendar: calendar) == day else { return nil }
        self.cadence = cadence
        if cadence == .week, let week = calendar.dateInterval(of: .weekOfYear, for: date),
           let end = calendar.date(byAdding: .day, value: -1, to: week.end) {
            startDay = Schedule.dayKey(week.start, calendar: calendar)
            endDay = Schedule.dayKey(end, calendar: calendar)
        } else {
            startDay = day
            endDay = day
        }
    }
}

public struct WorkReportInput: Codable, Equatable {
    public struct Event: Codable, Equatable {
        public let id: UUID
        public let at: Date
        public let timeZone: String
        public let segmentID: Int64
        public let source: String
        public let project: String
        public let action: WorkAction
        public let result: WorkResult
        public let evidence: WorkEvidence
        public let description: String
        public let editedByUser: Bool

        init(_ record: WorkActivityRecord) {
            id = record.id
            at = record.activity.at
            timeZone = record.timeZone
            segmentID = record.segmentID
            source = record.source
            project = record.activity.project
            action = record.activity.action
            result = record.activity.result
            evidence = record.activity.evidence
            description = record.description
            editedByUser = record.note != nil
        }
    }

    public let schemaVersion: Int
    public let channel: ReportChannel
    public let period: DigestPeriod
    public let regularSeconds: Int
    public let workSeconds: Int
    public let overtimeSeconds: Int
    public let events: [Event]
    public let segments: [RecordedSegment]?

    public init(period: DigestPeriod, totals: [ReportTotal], activities: [WorkActivityRecord],
                segments: [ReportEntry]? = nil) {
        schemaVersion = 1
        channel = .work
        self.period = period
        regularSeconds = Int(totals.filter { $0.bucket == .regular }.reduce(0) { $0 + $1.duration }.rounded())
        overtimeSeconds = Int(totals.filter { $0.bucket == .overtime }.reduce(0) { $0 + $1.duration }.rounded())
        workSeconds = regularSeconds + overtimeSeconds
        events = activities.filter { !$0.excluded }.map(Event.init)
        self.segments = segments?.filter { $0.bucket == .regular || $0.bucket == .overtime }.map(RecordedSegment.init)
    }


}

public struct LeisureReportInput: Codable, Equatable {
    public struct Source: Codable, Identifiable, Equatable {
        public let id: Int
        public let label: String
        public let seconds: Int
        public let segmentCount: Int
    }

    public let schemaVersion: Int
    public let channel: ReportChannel
    public let period: DigestPeriod
    public let leisureSeconds: Int
    public let sources: [Source]
    public let segments: [RecordedSegment]?

    public init(period: DigestPeriod, sources totals: [SourceTotal], segments: [ReportEntry]? = nil) {
        schemaVersion = 1
        channel = .leisure
        self.period = period
        leisureSeconds = Int(totals.reduce(0) { $0 + $1.duration }.rounded())
        self.segments = segments?.filter { $0.bucket == .entertainment }.map(RecordedSegment.init)
        sources = totals.enumerated().map {
            Source(id: $0.offset, label: $0.element.label, seconds: Int($0.element.duration.rounded()),
                   segmentCount: $0.element.count)
        }
    }
}

public enum WorkReportShare {
    private static let maxBytes = 8 * 1024 * 1024
    public static let lifetime: TimeInterval = 24 * 60 * 60

    public enum ShareError: Error {
        case invalidDay, invalidDirectory, unavailable, expired, invalidDocument
    }

    static var dataDirectory: URL {
        ProcessInfo.processInfo.environment["WORKANDPLAY_DATA_DIRECTORY"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WorkAndPlay", isDirectory: true)
    }

    public static var defaultDirectory: URL {
        dataDirectory.appendingPathComponent("approved-reports", isDirectory: true)
    }

    public static func json(_ report: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    public static func publish(_ data: Data, channel: ReportChannel, period: DigestPeriod,
                               in directory: URL = defaultDirectory) throws {
        let url = location(channel, period, in: directory)
        try validate(data, channel: channel, period: period)
        try writePrivate(data, to: url)
    }

    public static func read(_ channel: ReportChannel, period: DigestPeriod, in directory: URL = defaultDirectory,
                            now: Date = .now) throws -> Data {
        guard DigestPeriod(period.cadence, including: period.startDay) == period else { throw ShareError.invalidDay }
        let url = location(channel, period, in: directory)
        let (data, modified) = try readPrivate(url)
        let elapsed = now.timeIntervalSince(modified)
        guard (0..<lifetime).contains(elapsed) else { throw ShareError.expired }
        try validate(data, channel: channel, period: period)
        return data
    }

    static func readPrivate(_ url: URL) throws -> (Data, Date) {
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { throw ShareError.unavailable }
        try checkDirectory(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ShareError.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0,
              info.st_size > 0, info.st_size <= maxBytes else { throw ShareError.invalidDocument }
        guard let data = try handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else {
            throw ShareError.invalidDocument
        }
        return (data, Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)))
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        guard data.count <= maxBytes else { throw ShareError.invalidDocument }
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try checkDirectory(directory)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func revoke(_ channel: ReportChannel, period: DigestPeriod, in directory: URL = defaultDirectory) throws {
        guard DigestPeriod(period.cadence, including: period.startDay) == period else { throw ShareError.invalidDay }
        let url = location(channel, period, in: directory)
        try removePrivate(url)
    }

    public static func revokeCovering(_ day: String, channels: [ReportChannel] = ReportChannel.allCases,
                                      in directory: URL = defaultDirectory) throws {
        for cadence in ReportCadence.allCases {
            guard let period = DigestPeriod(cadence, including: day) else { continue }
            for channel in channels {
                try revoke(channel, period: period, in: directory)
            }
        }
    }

    private static func location(_ channel: ReportChannel, _ period: DigestPeriod, in directory: URL) -> URL {
        directory.appendingPathComponent("\(channel.rawValue)-\(period.cadence.rawValue)-\(period.startDay).json")
    }

    private static func validate(_ data: Data, channel: ReportChannel, period: DigestPeriod) throws {
        guard data.count <= maxBytes, DigestPeriod(period.cadence, including: period.startDay) == period else {
            throw ShareError.invalidDocument
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch channel {
        case .work:
            let report = try decoder.decode(WorkReportInput.self, from: data)
            guard report.schemaVersion == 1, report.channel == channel, report.period == period else {
                throw ShareError.invalidDocument
            }
        case .leisure:
            let report = try decoder.decode(LeisureReportInput.self, from: data)
            guard report.schemaVersion == 1, report.channel == channel, report.period == period else {
                throw ShareError.invalidDocument
            }
        }
    }

    static func removePrivate(_ url: URL) throws {
        let directory = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try checkDirectory(directory)
        if unlink(url.path) != 0 && errno != ENOENT { throw ShareError.unavailable }
    }

    private static func checkDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else { throw ShareError.invalidDirectory }
    }
}
