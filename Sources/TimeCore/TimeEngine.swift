import Foundation

public struct Preferences: Codable, Equatable, Sendable {
    public var idleSeconds = 180
    public var readingSeconds = 120
    public var countVideo = false
    public var countIdleAsEntertainment = false
    public var paused = false
    public var schedule = Schedule()
    public var rules: [Rule] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case idleSeconds, readingSeconds, countVideo, countIdleAsEntertainment, paused, schedule, rules
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        idleSeconds = try values.decode(Int.self, forKey: .idleSeconds)
        readingSeconds = try values.decode(Int.self, forKey: .readingSeconds)
        countVideo = try values.decode(Bool.self, forKey: .countVideo)
        countIdleAsEntertainment = try values.decodeIfPresent(Bool.self, forKey: .countIdleAsEntertainment) ?? false
        paused = try values.decode(Bool.self, forKey: .paused)
        schedule = try values.decode(Schedule.self, forKey: .schedule)
        rules = try values.decode([Rule].self, forKey: .rules)
    }
}

public struct Foreground: Equatable, Sendable {
    /// Process, window or tab identity. Used only in memory.
    public let token: String
    public let classification: Classification

    public init(token: String, classification: Classification) {
        self.token = token
        self.classification = classification
    }
}

public enum SystemIdleReason: Equatable, Sendable {
    case locked, sleeping

    var basis: ClassificationBasis { self == .locked ? .screenLocked : .systemSleeping }
}

public struct Observation: Sendable {
    public let foreground: Foreground?
    public let input: Date?
    public let reading: Date?
    public let videoPlaying: Bool
    public let suspended: Bool
    public let validUntil: Date?
    public let monitorsIdle: Bool
    public let deviceInput: Date?
    public let systemIdle: SystemIdleReason?

    public init(foreground: Foreground? = nil, input: Date? = nil, reading: Date? = nil,
                videoPlaying: Bool = false, suspended: Bool = false, validUntil: Date? = nil,
                monitorsIdle: Bool = false, deviceInput: Date? = nil, systemIdle: SystemIdleReason? = nil) {
        self.foreground = foreground
        self.input = input
        self.reading = reading
        self.videoPlaying = videoPlaying
        self.suspended = suspended
        self.validUntil = validUntil
        self.monitorsIdle = monitorsIdle
        self.deviceInput = deviceInput
        self.systemIdle = systemIdle
    }
}

public enum Bucket: String, CaseIterable, Codable, Identifiable, Sendable {
    case regular, overtime, entertainment, review
    public var id: Self { self }

    public static func forCategory(_ category: ActivityCategory, restReason: String?) -> Self? {
        if restReason != nil { return category == .work ? .overtime : nil }
        switch category {
        case .work: return .regular
        case .entertainment: return .entertainment
        case .unclassified: return .review
        }
    }
}

public struct TimeSlice: Equatable, Sendable {
    public let start: Date
    public let end: Date
    public let day: String
    public let timeZoneID: String
    public let activity: Classification
    public let bucket: Bucket
    public let restReason: String?
    public let spanID: UUID
    public let visitID: UUID?

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct TimeEngine {
    public private(set) var preferences: Preferences
    public private(set) var calendar: Calendar
    private var cursor: Date?
    private var foreground: Foreground?
    private var lastInteraction: Date?
    private var video = false
    private var validUntil: Date?
    private var focusStart: Date?
    private var spanID = UUID()
    private var websiteVisit: (token: String, host: String, id: UUID)?
    private var deviceIdle: (lastActivity: Date, spanID: UUID)?
    private var systemIdle: (reason: SystemIdleReason, spanID: UUID)?

    public var systemIdleReason: SystemIdleReason? { systemIdle?.reason }

    public init(preferences: Preferences = Preferences(), calendar: Calendar) {
        self.preferences = preferences
        self.calendar = calendar
    }

    public func active(at date: Date) -> Bool {
        guard let cursor, let end = deadline, date >= cursor else { return false }
        return date < end
    }

    public func recordingIdle(at date: Date) -> Bool {
        guard let cursor, date >= cursor, !active(at: date) else { return false }
        guard systemIdle != nil || idleStart.map({ date >= $0 }) == true else { return false }
        return preferences.schedule.activeBucket(for: .entertainment, at: date, calendar: calendar) == .entertainment
    }

    /// Only call after an interval of observed coverage.
    public mutating func observe(at date: Date, _ sample: Observation) -> [TimeSlice] {
        if let cursor, date < cursor { return [] }
        let previousEnd = deadline
        let observedDeviceInput = sample.deviceInput.flatMap { input -> Date? in
            guard let deviceIdle, input > deviceIdle.lastActivity, input <= date else { return nil }
            return input
        }
        let slices = advance(to: date, deviceInput: observedDeviceInput)
        if preferences.countIdleAsEntertainment, !preferences.paused, let reason = sample.systemIdle {
            if systemIdle?.reason != reason { systemIdle = (reason, UUID()) }
        } else {
            systemIdle = nil
        }
        let suspended = sample.suspended || sample.systemIdle != nil || preferences.paused
        if preferences.countIdleAsEntertainment && sample.monitorsIdle && !suspended {
            if let observedDeviceInput { deviceIdle = (observedDeviceInput, UUID()) }
            else if deviceIdle == nil { deviceIdle = (date, UUID()) }
        } else {
            deviceIdle = nil
        }
        guard !suspended, let observed = sample.foreground else {
            resetFocus()
            websiteVisit = nil
            return slices
        }

        let lostCoverage = validUntil.map { $0 <= date } ?? false
        if let host = observed.classification.host.flatMap(Privacy.host) {
            if websiteVisit?.token != observed.token || websiteVisit?.host != host || lostCoverage {
                websiteVisit = (observed.token, host, UUID())
            }
        } else {
            websiteVisit = nil
        }

        if foreground != observed || lostCoverage {
            resetFocus()
            foreground = observed
            focusStart = date
        }

        let playing = sample.videoPlaying && preferences.countVideo
            && foreground?.classification.category == .entertainment
        let stoppedVideo = video && !playing
        if stoppedVideo { lastInteraction = nil }
        video = playing
        validUntil = sample.validUntil
        let signal = foreground?.classification.kind == .reading ? sample.reading : sample.input
        if !stoppedVideo, let signal, let focusStart, signal >= focusStart, signal <= date,
           lastInteraction.map({ signal > $0 }) ?? true {
            lastInteraction = signal
        }
        if let previousEnd, previousEnd < date { spanID = UUID() }
        if stoppedVideo { spanID = UUID() }
        return slices
    }

    /// Clear provenance after sleep gaps, a clock discontinuity or capture failure.
    public mutating func discardCoverage() {
        cursor = nil
        resetFocus()
        websiteVisit = nil
        deviceIdle = nil
        systemIdle = nil
    }

    public mutating func reconfigure(_ preferences: Preferences, calendar: Calendar) {
        self.preferences = preferences
        self.calendar = calendar
        discardCoverage()
    }

    private var deadline: Date? {
        guard let foreground else { return nil }
        let threshold = foreground.classification.kind == .reading ? preferences.readingSeconds : preferences.idleSeconds
        let expiry = video ? Date.distantFuture : lastInteraction?.addingTimeInterval(Double(max(1, threshold)))
        guard let expiry else { return nil }
        return min(expiry, validUntil ?? .distantFuture)
    }

    private var idleStart: Date? {
        deviceIdle?.lastActivity.addingTimeInterval(Double(max(1, preferences.idleSeconds)))
    }

    private mutating func advance(to date: Date, deviceInput: Date?) -> [TimeSlice] {
        defer { cursor = date }
        guard let cursor, cursor < date else { return [] }
        if let systemIdle {
            return recording(from: cursor, to: date, activity: .idle(basis: systemIdle.reason.basis), span: systemIdle.spanID, visit: nil)
        }
        let activityEnd = min(date, deadline ?? cursor)
        var slices: [TimeSlice] = []
        if let activity = foreground?.classification, cursor < activityEnd {
            slices = recording(from: cursor, to: activityEnd, activity: activity, span: spanID, visit: websiteVisit?.id)
        }
        if let idleStart, let deviceIdle {
            let start = max(cursor, activityEnd, idleStart)
            let end = min(date, deviceInput ?? date)
            if start < end {
                slices += recording(from: start, to: end, activity: .deviceIdle, span: deviceIdle.spanID, visit: nil)
            }
        }
        return slices
    }

    private func recording(from start: Date, to end: Date, activity: Classification, span: UUID, visit: UUID?) -> [TimeSlice] {
        preferences.schedule.split(DateInterval(start: start, end: end), calendar: calendar).compactMap { range in
            guard let bucket = Bucket.forCategory(activity.category, restReason: range.restReason) else { return nil }
            return TimeSlice(start: range.start, end: range.end, day: range.day, timeZoneID: calendar.timeZone.identifier, activity: activity,
                             bucket: bucket, restReason: range.restReason, spanID: span, visitID: visit)
        }
    }

    private mutating func resetFocus() {
        foreground = nil
        focusStart = nil
        lastInteraction = nil
        validUntil = nil
        video = false
        spanID = UUID()
    }
}
