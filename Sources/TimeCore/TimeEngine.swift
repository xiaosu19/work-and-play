import Foundation

public struct Preferences: Codable, Equatable, Sendable {
    public var idleSeconds = 180
    public var readingSeconds = 120
    public var countVideo = false
    public var paused = false
    public var schedule = Schedule()
    public var rules: [Rule] = []

    public init() {}
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

public struct Observation: Sendable {
    public let foreground: Foreground?
    public let input: Date?
    public let reading: Date?
    public let videoPlaying: Bool
    public let suspended: Bool
    public let validUntil: Date?

    public init(foreground: Foreground? = nil, input: Date? = nil, reading: Date? = nil,
                videoPlaying: Bool = false, suspended: Bool = false, validUntil: Date? = nil) {
        self.foreground = foreground
        self.input = input
        self.reading = reading
        self.videoPlaying = videoPlaying
        self.suspended = suspended
        self.validUntil = validUntil
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

    public init(preferences: Preferences = Preferences(), calendar: Calendar) {
        self.preferences = preferences
        self.calendar = calendar
    }

    public func active(at date: Date) -> Bool {
        guard let cursor, let end = deadline, date >= cursor else { return false }
        return date < end
    }

    /// Only call after an interval of observed coverage.
    public mutating func observe(at date: Date, _ sample: Observation) -> [TimeSlice] {
        if let cursor, date < cursor { return [] }
        let previousEnd = deadline
        let slices = advance(to: date)
        guard !sample.suspended, !preferences.paused, let observed = sample.foreground else {
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

    private mutating func advance(to date: Date) -> [TimeSlice] {
        defer { cursor = date }
        guard let cursor, let expiry = deadline, let activity = foreground?.classification else { return [] }
        let end = min(date, expiry)
        guard cursor < end else { return [] }
        return preferences.schedule.split(DateInterval(start: cursor, end: end), calendar: calendar).compactMap { range in
            guard let bucket = Bucket.forCategory(activity.category, restReason: range.restReason) else { return nil }
            return TimeSlice(start: range.start, end: range.end, day: range.day, timeZoneID: calendar.timeZone.identifier, activity: activity,
                             bucket: bucket, restReason: range.restReason, spanID: spanID, visitID: websiteVisit?.id)
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
