import Foundation
import CSQLite
import TimeCore

public enum StoreError: Error {
    case sqlite(Int32)
    case invalidCorrection
}

public struct WorkActivityRecord: Identifiable, Codable, Equatable {
    public var id: UUID { activity.id }
    public let activity: WorkActivity
    public let segmentID: Int64
    public let source: String
    public let timeZone: String
    public let note: String?
    public let excluded: Bool

    public var description: String { note ?? activity.description }
}

public struct ReportEntry: Identifiable, Equatable {
    public let id: Int64
    public let start: Date
    public let end: Date
    public let day: String
    public let timeZoneID: String
    public let category: ActivityCategory
    public let bucket: Bucket
    public let restReason: String?
    public let appID: String
    public let appName: String
    public let host: String?
    public let kind: ActivityKind
    public let ruleID: UUID?
    public let basis: ClassificationBasis
    public let corrected: Bool

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var label: String { host ?? appName }
}

public struct DailyReport {
    public let entries: [ReportEntry]

    public init(entries: [ReportEntry] = []) {
        self.entries = entries
    }

    public func total(_ bucket: Bucket) -> TimeInterval {
        entries.lazy.filter { $0.bucket == bucket }.reduce(0) { $0 + $1.duration }
    }

    public func unrecordedOrdinaryIntervals(schedule: Schedule) -> [DateInterval] {
        let sorted = entries.sorted { $0.start < $1.start }
        guard let first = sorted.first, let end = sorted.map(\.end).max(), first.start < end,
              sorted.allSatisfy({ $0.day == first.day && $0.timeZoneID == first.timeZoneID }),
              let zone = TimeZone(identifier: first.timeZoneID) else { return [] }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let ordinaryIntervals = schedule.ordinaryIntervals(within: DateInterval(start: first.start, end: end), calendar: calendar)
        var recordedThrough = first.end
        var gaps: [DateInterval] = []
        for entry in sorted.dropFirst() {
            if recordedThrough < entry.start {
                for interval in ordinaryIntervals {
                    let start = max(recordedThrough, interval.start)
                    let end = min(entry.start, interval.end)
                    if start < end {
                        gaps.append(DateInterval(start: start, end: end))
                    }
                }
            }
            recordedThrough = max(recordedThrough, entry.end)
        }
        return gaps
    }
}

public struct ReportTotal {
    public let day: String
    public let bucket: Bucket
    public let duration: TimeInterval
    public let count: Int
}

public enum ReportSource: Hashable {
    case application(String, host: String?)
    case entireApplication(String)
    case website(String)

    public var appID: String? {
        switch self {
        case .application(let id, _), .entireApplication(let id): id
        case .website: nil
        }
    }

    public var host: String? {
        switch self {
        case let .application(_, host): host
        case .entireApplication: nil
        case let .website(host): host
        }
    }
}

public struct SourceTotal: Identifiable {
    public let id: ReportSource
    public let appName: String
    public let duration: TimeInterval
    public let count: Int

    public var label: String { id.host ?? appName }
}

public struct SourceBreakdown: Identifiable {
    public let total: SourceTotal
    public let byBucket: [Bucket: TimeInterval]

    public var id: ReportSource { total.id }
    public var work: TimeInterval { byBucket[.regular, default: 0] + byBucket[.overtime, default: 0] }
    public var entertainment: TimeInterval { byBucket[.entertainment, default: 0] }
    public var isMixed: Bool { work > 0 && entertainment > 0 }
}

public struct WebsiteTotal: Identifiable {
    public let id: String
    public let visits: Int
    public let hasEarlierFragments: Bool
    public let work: TimeInterval
    public let entertainment: TimeInterval
    public let count: Int

    public var duration: TimeInterval { work + entertainment }
    public var source: SourceTotal {
        SourceTotal(id: .website(id), appName: id, duration: duration, count: count)
    }
}

public final class SQLiteStore {
    private let db: OpaquePointer

    public init(path: String) throws {
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let connection else {
            sqlite3_close(connection)
            throw StoreError.sqlite(result)
        }
        db = connection
        do {
            sqlite3_busy_timeout(db, 1500)
            try run("PRAGMA secure_delete = ON")
            try run("PRAGMA foreign_keys = ON")
            try run("PRAGMA journal_mode = DELETE")
            try run("""
                CREATE TABLE IF NOT EXISTS preferences (id INTEGER PRIMARY KEY CHECK (id = 1), json BLOB NOT NULL);
                """)
            try run("""
                CREATE TABLE IF NOT EXISTS slice (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  start REAL NOT NULL, end REAL NOT NULL CHECK (end > start),
                  day TEXT NOT NULL, time_zone TEXT NOT NULL, span TEXT NOT NULL,
                  category TEXT NOT NULL CHECK (category IN ('work','entertainment','unclassified')),
                  bucket TEXT NOT NULL CHECK (bucket IN ('regular','overtime','entertainment','review')),
                  rest_reason TEXT,
                  app_id TEXT NOT NULL, app_name TEXT NOT NULL, host TEXT, kind TEXT NOT NULL, rule_id TEXT,
                  basis TEXT NOT NULL, corrected INTEGER NOT NULL DEFAULT 0 CHECK (corrected IN (0,1)), visit_id TEXT,
                  CHECK ((rest_reason IS NOT NULL AND bucket = 'overtime' AND category = 'work')
                     OR (rest_reason IS NULL AND ((category = 'work' AND bucket = 'regular')
                       OR (category = 'entertainment' AND bucket = 'entertainment')
                       OR (category = 'unclassified' AND bucket = 'review'))))
                )
                """)
            try transaction {
                let columns = try query("PRAGMA table_info(slice)") { string($0, 1) }
                if !columns.contains("visit_id") { try run("ALTER TABLE slice ADD COLUMN visit_id TEXT") }
            }
            try run("CREATE INDEX IF NOT EXISTS slice_day ON slice(day, start)")
            try run("CREATE INDEX IF NOT EXISTS slice_end ON slice(end)")
            try run("CREATE INDEX IF NOT EXISTS slice_website_day ON slice(day, host, visit_id) WHERE host IS NOT NULL")
            try run("""
                CREATE TABLE IF NOT EXISTS work_activity (
                    id TEXT PRIMARY KEY, slice_id INTEGER NOT NULL REFERENCES slice(id) ON DELETE CASCADE,
                    at REAL NOT NULL, project TEXT NOT NULL, action TEXT NOT NULL,
                    result TEXT NOT NULL, evidence TEXT NOT NULL, note TEXT,
                    excluded INTEGER NOT NULL DEFAULT 0 CHECK (excluded IN (0,1))
                )
                """)
            try run("CREATE INDEX IF NOT EXISTS work_activity_slice ON work_activity(slice_id, at)")
            try prepareOperationJSONQueue()
            // Rebuild the projection when opening older stores; the original fragments stay intact.
            try transaction {
                try run("DROP VIEW IF EXISTS reported_slice")
                try run("""
                    CREATE VIEW reported_slice AS
                    SELECT id, start, end, day, time_zone,
                        CASE WHEN category = 'unclassified' AND NOT missing_browser_page
                             THEN 'entertainment' ELSE category END AS category,
                        CASE WHEN bucket = 'review' AND NOT missing_browser_page
                             THEN 'entertainment' ELSE bucket END AS bucket,
                        rest_reason, app_id, app_name, host, kind, rule_id, basis, corrected
                    FROM (
                        SELECT slice.*, host IS NULL AND lower(app_id) IN ('com.google.chrome', 'com.microsoft.edgemac')
                            AS missing_browser_page FROM slice
                    )
                    """)
            }
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    private func prepareOperationJSONQueue() throws {
        try run("CREATE TABLE IF NOT EXISTS operation_json_pending (day TEXT PRIMARY KEY)")
        // Track dirty dates in the same transaction as committed slices and descriptions.
        for (action, row) in [("INSERT", "NEW"), ("UPDATE", "NEW"), ("DELETE", "OLD")] {
            try run("""
                CREATE TRIGGER IF NOT EXISTS operation_json_slice_\(action.lowercased()) AFTER \(action) ON slice
                BEGIN
                    INSERT INTO operation_json_pending (day) VALUES (\(row).day)
                        ON CONFLICT(day) DO NOTHING;
                END
                """)
            try run("""
                CREATE TRIGGER IF NOT EXISTS operation_json_activity_\(action.lowercased()) AFTER \(action) ON work_activity
                BEGIN
                    INSERT INTO operation_json_pending SELECT day FROM slice WHERE id = \(row).slice_id
                        ON CONFLICT(day) DO NOTHING;
                END
                """)
        }
    }

    public func enqueueOperationJSON(day: String) throws {
        try run("INSERT INTO operation_json_pending VALUES (?) ON CONFLICT(day) DO NOTHING", [.text(day)])
    }

    public func syncOperationJSON(in directory: URL = OperationJSON.directory, limit: Int = 4) throws -> Int {
        let days = try query("SELECT day FROM operation_json_pending ORDER BY day DESC LIMIT ?", [.integer(Int64(limit))]) {
            string($0, 0) ?? ""
        }
        var written = 0
        for day in days {
            if let period = DigestPeriod(.day, including: day) {
                let segments = try report(day: day).entries
                let work = WorkReportInput(period: period, totals: try totals(from: day, through: day),
                    activities: try workActivities(from: day, through: day), segments: segments)
                let leisure = LeisureReportInput(period: period,
                    sources: try sourceTotals(from: day, through: day, bucket: .entertainment), segments: segments)
                try OperationJSON.write(work, leisure, in: directory)
                written += 1
            }
            try run("DELETE FROM operation_json_pending WHERE day = ?", [.text(day)])
        }
        return written
    }

    public func preferences() throws -> Preferences {
        let saved = try query("SELECT json FROM preferences WHERE id = 1") { statement in
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw StoreError.sqlite(SQLITE_CORRUPT) }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            return try JSONDecoder().decode(Preferences.self, from: data)
        }.first
        if let saved { return saved }
        let defaults = Preferences()
        try save(defaults)
        return defaults
    }

    public func save(_ preferences: Preferences) throws {
        try run("INSERT INTO preferences VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
                [.blob(try JSONEncoder().encode(preferences))])
    }

    public func append(_ slices: [TimeSlice], activities: [PendingWorkActivity] = []) throws {
        guard !slices.isEmpty || !activities.isEmpty else { return }
        try transaction {
            var lastEnd = try latestEnd() ?? .distantPast
            for slice in slices {
                let start = max(slice.start, lastEnd)
                guard start < slice.end else { continue }
                let activity = slice.activity
                let attributes: [Value] = [.text(slice.day), .text(slice.timeZoneID), .text(slice.spanID.uuidString), .text(activity.category.rawValue),
                    .text(slice.bucket.rawValue), .optional(slice.restReason), .text(activity.appID),
                    .text(activity.appName), .optional(activity.host.flatMap(Privacy.host)), .text(activity.kind.rawValue),
                    .optional(activity.ruleID?.uuidString), .text(activity.basis.rawValue), .optional(slice.visitID?.uuidString)]
                try run("""
                    UPDATE slice SET end = ? WHERE end = ? AND day = ? AND time_zone = ? AND span = ? AND category = ?
                      AND bucket = ? AND rest_reason IS ? AND app_id = ? AND app_name = ? AND host IS ?
                      AND kind = ? AND rule_id IS ? AND basis = ? AND visit_id IS ? AND corrected = 0
                    """, [.date(slice.end), .date(start)] + attributes)
                if sqlite3_changes(db) == 0 {
                    try run("""
                        INSERT INTO slice(start, end, day, time_zone, span, category, bucket, rest_reason, app_id, app_name,
                          host, kind, rule_id, basis, visit_id) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """, [.date(start), .date(slice.end)] + attributes)
                }
                lastEnd = slice.end
            }
            for pending in activities where pending.activity.valid {
                let activity = pending.activity
                // A new phase of the same browser action promotes its result in place.
                try run("""
                    INSERT INTO work_activity (id,slice_id,at,project,action,result,evidence)
                    SELECT ?,id,?,?,?,?,? FROM slice
                    WHERE span = ? AND category = 'work' AND start <= ? AND end > ?
                    ON CONFLICT(id) DO UPDATE SET result = excluded.result, evidence = excluded.evidence
                    WHERE work_activity.slice_id = excluded.slice_id
                        AND work_activity.action = excluded.action AND work_activity.project = excluded.project
                        AND work_activity.result = 'attempted' AND excluded.result = 'confirmed'
                    """, [.text(activity.id.uuidString), .date(activity.at), .text(activity.project),
                           .text(activity.action.rawValue), .text(activity.result.rawValue), .text(activity.evidence.rawValue),
                           .text(pending.spanID.uuidString), .date(activity.at), .date(activity.at)])
            }
        }
    }

    public func workActivities(from firstDay: String, through lastDay: String,
                               segmentID: Int64? = nil) throws -> [WorkActivityRecord] {
        var condition = "slice.day BETWEEN ? AND ? AND slice.category = 'work'"
        var values: [Value] = [.text(firstDay), .text(lastDay)]
        if let segmentID {
            condition += " AND slice.id = ?"
            values.append(.integer(segmentID))
        }
        return try query("""
            SELECT ev.id,ev.at,ev.project,ev.action,ev.result,ev.evidence,ev.slice_id,
                   COALESCE(slice.host, slice.app_name),slice.time_zone,ev.note,ev.excluded
            FROM work_activity AS ev JOIN slice ON slice.id = ev.slice_id
            WHERE \(condition) ORDER BY ev.at, ev.id
            """, values) { row in
            guard let id = string(row, 0).flatMap(UUID.init(uuidString:)), let project = string(row, 2),
                  let action = string(row, 3).flatMap(WorkAction.init(rawValue:)),
                  let result = string(row, 4).flatMap(WorkResult.init(rawValue:)),
                  let evidence = string(row, 5).flatMap(WorkEvidence.init(rawValue:)),
                  let source = string(row, 7), let zone = string(row, 8) else { throw StoreError.sqlite(SQLITE_CORRUPT) }
            return WorkActivityRecord(activity: WorkActivity(id: id, at: timestamp(row, 1), project: project,
                action: action, result: result, evidence: evidence), segmentID: sqlite3_column_int64(row, 6),
                source: source, timeZone: zone, note: string(row, 9), excluded: sqlite3_column_int(row, 10) == 1)
        }
    }

    public func updateWorkActivity(_ id: UUID, note: String?, excluded: Bool) throws {
        guard note?.utf8.count ?? 0 <= 600, note?.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw StoreError.invalidCorrection
        }
        try run("UPDATE work_activity SET note = ?, excluded = ? WHERE id = ?",
                [.optional(note), .integer(excluded ? 1 : 0), .text(id.uuidString)])
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalidCorrection }
    }

    public func addWorkNote(to segmentID: Int64, project: String, note: String) throws {
        let activity = WorkActivity(at: .now, project: project, action: .manualNote, result: .reported, evidence: .userNote)
        guard activity.valid, !note.isEmpty, note.utf8.count <= 600, note.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw StoreError.invalidCorrection
        }
        try run("""
            INSERT INTO work_activity (id,slice_id,at,project,action,result,evidence,note)
            SELECT ?,id,start,?,?,?,?,? FROM slice WHERE id = ? AND category = 'work'
            """, [.text(activity.id.uuidString), .text(project), .text(activity.action.rawValue),
                   .text(activity.result.rawValue), .text(activity.evidence.rawValue), .text(note), .integer(segmentID)])
        guard sqlite3_changes(db) == 1 else { throw StoreError.invalidCorrection }
    }

    public func deleteWorkActivity(_ id: UUID) throws {
        try run("DELETE FROM work_activity WHERE id = ?", [.text(id.uuidString)])
    }

    public func latestEnd() throws -> Date? {
        try query("SELECT end FROM slice ORDER BY end DESC LIMIT 1") { timestamp($0, 0) }.first
    }

    public func report(day: String) throws -> DailyReport {
        try report(from: day, through: day)
    }

    public func fragment(id: Int64) throws -> ReportEntry? {
        try query("""
            SELECT id, start, end, category, bucket, rest_reason, app_id, app_name, host, kind, rule_id,
              time_zone, basis, corrected, day
            FROM reported_slice WHERE id = ?
            """, [.integer(id)], readEntry).first
    }

    public func report(from firstDay: String, through lastDay: String, bucket: Bucket? = nil,
                       source: ReportSource? = nil, limit: Int = -1, offset: Int = 0, newestFirst: Bool = false) throws -> DailyReport {
        let filter = Self.reportFilter(firstDay: firstDay, lastDay: lastDay, bucket: bucket, source: source)
        let order = newestFirst ? "day DESC, start DESC" : "day, start"
        return DailyReport(entries: try query("""
            SELECT id, start, end, category, bucket, rest_reason, app_id, app_name, host, kind, rule_id,
              time_zone, basis, corrected, day
            FROM reported_slice WHERE \(filter.condition) ORDER BY \(order) LIMIT ? OFFSET ?
            """, filter.values + [.integer(Int64(limit)), .integer(Int64(offset))], readEntry))
    }

    public func totals(from firstDay: String, through lastDay: String) throws -> [ReportTotal] {
        try query("""
            SELECT day, bucket, SUM(end-start), COUNT(*) FROM reported_slice
            WHERE day BETWEEN ? AND ? GROUP BY day, bucket ORDER BY day
            """, [.text(firstDay), .text(lastDay)]) { row in
                guard let day = string(row, 0), let bucket = string(row, 1).flatMap(Bucket.init(rawValue:)) else {
                    throw StoreError.sqlite(SQLITE_CORRUPT)
                }
                return ReportTotal(day: day, bucket: bucket, duration: sqlite3_column_double(row, 2),
                                   count: Int(sqlite3_column_int64(row, 3)))
            }
    }

    public func sourceTotals(from firstDay: String, through lastDay: String, bucket: Bucket?) throws -> [SourceTotal] {
        try sourceBreakdown(from: firstDay, through: lastDay, bucket: bucket).map(\.total)
    }

    public func sourceBreakdown(from firstDay: String, through lastDay: String, bucket: Bucket? = nil,
                                groupByApplication: Bool = false) throws -> [SourceBreakdown] {
        var filter = Self.reportFilter(firstDay: firstDay, lastDay: lastDay, bucket: bucket, source: nil)
        if groupByApplication {
            filter.condition += " AND app_id <> ?"
            filter.values.append(.text(Classification.deviceIdle.appID))
        }
        let hostColumn = groupByApplication ? "NULL" : "host"
        let grouping = groupByApplication ? "app_id, bucket" : "app_id, host, bucket"
        let rows = try query("""
            SELECT app_id, \(hostColumn), MIN(app_name), SUM(end-start), COUNT(*), bucket
            FROM reported_slice WHERE \(filter.condition) GROUP BY \(grouping)
            """, filter.values) { row -> (source: SourceTotal, bucket: Bucket) in
                guard let appID = string(row, 0), let appName = string(row, 2),
                      let bucket = string(row, 5).flatMap(Bucket.init(rawValue:)) else {
                    throw StoreError.sqlite(SQLITE_CORRUPT)
                }
                let identity: ReportSource = groupByApplication ? .entireApplication(appID) : .application(appID, host: string(row, 1))
                let source = SourceTotal(id: identity, appName: appName,
                                         duration: sqlite3_column_double(row, 3), count: Int(sqlite3_column_int64(row, 4)))
                return (source, bucket)
            }

        return Dictionary(grouping: rows, by: { $0.source.id }).map { id, parts in
            let duration = parts.reduce(0) { $0 + $1.source.duration }
            let count = parts.reduce(0) { $0 + $1.source.count }
            let total = SourceTotal(id: id, appName: parts.map { $0.source.appName }.min() ?? id.appID ?? "",
                                    duration: duration, count: count)
            return SourceBreakdown(total: total,
                                   byBucket: Dictionary(uniqueKeysWithValues: parts.map { ($0.bucket, $0.source.duration) }))
        }.sorted {
            if $0.total.duration != $1.total.duration { return $0.total.duration > $1.total.duration }
            if $0.total.label != $1.total.label { return $0.total.label < $1.total.label }
            return ($0.id.appID ?? "") < ($1.id.appID ?? "")
        }
    }

    public func websiteTotals(from firstDay: String, through lastDay: String) throws -> [WebsiteTotal] {
        try query("""
            SELECT host, COUNT(DISTINCT visit_id), COUNT(*) > COUNT(visit_id),
                SUM(CASE WHEN category = 'work' THEN end-start ELSE 0 END),
                SUM(CASE WHEN category <> 'work' THEN end-start ELSE 0 END), COUNT(*)
            FROM slice WHERE day BETWEEN ? AND ? AND host IS NOT NULL
            GROUP BY host ORDER BY SUM(end-start) DESC, host
            """, [.text(firstDay), .text(lastDay)]) { row in
                guard let host = string(row, 0) else { throw StoreError.sqlite(SQLITE_CORRUPT) }
                return WebsiteTotal(id: host, visits: Int(sqlite3_column_int64(row, 1)),
                    hasEarlierFragments: sqlite3_column_int(row, 2) != 0, work: sqlite3_column_double(row, 3),
                    entertainment: sqlite3_column_double(row, 4), count: Int(sqlite3_column_int64(row, 5)))
            }
    }

    private static func reportFilter(firstDay: String, lastDay: String, bucket: Bucket?, source: ReportSource?)
        -> (condition: String, values: [Value]) {
        var condition = "day BETWEEN ? AND ?"
        var values: [Value] = [.text(firstDay), .text(lastDay)]
        if let bucket {
            condition += " AND bucket = ?"
            values.append(.text(bucket.rawValue))
        }
        switch source {
        case let .application(appID, host):
            condition += " AND app_id = ? AND host IS ?"
            values += [.text(appID), .optional(host)]
        case let .entireApplication(appID):
            condition += " AND app_id = ?"
            values.append(.text(appID))
        case let .website(host):
            condition += " AND host = ?"
            values.append(.text(host))
        case nil:
            break
        }
        return (condition, values)
    }

    public func classifyExistingUnknownSources() throws {
        try transaction {
            let sources = try query("""
                SELECT DISTINCT app_id, host FROM slice
                WHERE bucket = 'review' AND corrected = 0 AND basis = 'none' AND rest_reason IS NULL
                """) { row in
                    let id = string(row, 0) ?? ""
                    return ActivityIdentity(appID: id, appName: id, host: string(row, 1))
                }
            for source in sources {
                let decision = Rule.classify(source, using: [])
                guard decision.category != .unclassified,
                      let bucket = Bucket.forCategory(decision.category, restReason: nil) else { continue }
                try run("""
                    UPDATE slice SET bucket = ?, category = ?, basis = ?
                    WHERE bucket = 'review' AND corrected = 0 AND basis = 'none' AND rest_reason IS NULL
                      AND app_id = ? AND host IS ?
                    """, [.text(bucket.rawValue), .text(decision.category.rawValue), .text(decision.basis.rawValue),
                           .text(source.appID), .optional(source.host)])
            }
        }
    }

    public func correct(entry: ReportEntry, to category: ActivityCategory, saving preferences: Preferences? = nil) throws {
        try transaction {
            if let bucket = Bucket.forCategory(category, restReason: entry.restReason) {
                try run("UPDATE slice SET category = ?, bucket = ?, span = ?, corrected = 1 WHERE id = ?",
                        [.text(category.rawValue), .text(bucket.rawValue), .text(UUID().uuidString), .integer(entry.id)])
            } else {
                try run("DELETE FROM slice WHERE id = ?", [.integer(entry.id)])
            }
            guard sqlite3_changes(db) == 1 else { throw StoreError.invalidCorrection }
            if category != .work {
                try run("DELETE FROM work_activity WHERE slice_id = ?", [.integer(entry.id)])
            }
            if let preferences { try save(preferences) }
        }
    }

    private func readEntry(_ statement: OpaquePointer) throws -> ReportEntry {
        guard let category = string(statement, 3).flatMap(ActivityCategory.init(rawValue:)),
              let bucket = string(statement, 4).flatMap(Bucket.init(rawValue:)),
              let appID = string(statement, 6), let appName = string(statement, 7),
              let kind = string(statement, 9).flatMap(ActivityKind.init(rawValue:)),
              let timeZoneID = string(statement, 11),
              let basis = string(statement, 12).flatMap(ClassificationBasis.init(rawValue:)),
              let day = string(statement, 14) else {
            throw StoreError.sqlite(SQLITE_CORRUPT)
        }
        return ReportEntry(id: sqlite3_column_int64(statement, 0), start: timestamp(statement, 1),
            end: timestamp(statement, 2), day: day, timeZoneID: timeZoneID, category: category, bucket: bucket, restReason: string(statement, 5),
            appID: appID, appName: appName, host: string(statement, 8), kind: kind,
            ruleID: string(statement, 10).flatMap(UUID.init(uuidString:)),
            basis: basis, corrected: sqlite3_column_int(statement, 13) == 1)
    }

    private func timestamp(_ statement: OpaquePointer, _ index: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func string(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do {
            try body()
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    private func run(_ sql: String, _ values: [Value] = []) throws {
        _ = try query(sql, values) { _ in true }
    }

    private func query<T>(_ sql: String, _ values: [Value] = [], _ read: (OpaquePointer) throws -> T) throws -> [T] {
        var prepared: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &prepared, nil)
        guard result == SQLITE_OK, let prepared else { throw StoreError.sqlite(result) }
        defer { sqlite3_finalize(prepared) }

        for (offset, value) in values.enumerated() {
            let result = value.bind(prepared, Int32(offset + 1))
            guard result == SQLITE_OK else { throw StoreError.sqlite(result) }
        }

        var rows: [T] = []
        while true {
            switch sqlite3_step(prepared) {
            case SQLITE_DONE: return rows
            case SQLITE_ROW: rows.append(try read(prepared))
            case let failure: throw StoreError.sqlite(failure)
            }
        }
    }

    private enum Value {
        case text(String), integer(Int64), date(Date), blob(Data), null

        static func optional(_ string: String?) -> Self { string.map(Self.text) ?? .null }

        func bind(_ statement: OpaquePointer, _ index: Int32) -> Int32 {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            switch self {
            case .text(let string): return sqlite3_bind_text(statement, index, string, -1, transient)
            case .integer(let integer): return sqlite3_bind_int64(statement, index, integer)
            case .date(let date): return sqlite3_bind_double(statement, index, date.timeIntervalSince1970)
            case .blob(let data):
                return data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
                }
            case .null: return sqlite3_bind_null(statement, index)
            }
        }
    }
}
