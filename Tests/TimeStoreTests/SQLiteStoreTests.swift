import Foundation
import TimeCore
import TimeStore

final class SQLiteStoreTests {
    func testPrivacyTotalsCorrectionAndRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite3")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12))!
        let day = Schedule.dayKey(noon, calendar: calendar)
        var preferences = Preferences()
        preferences.countVideo = true
        preferences.schedule.weekdays[4] = [RestPeriod(start: 720, end: 780)]
        let rules = [Rule(host: "work.example", pathPrefix: "/projects", category: .work),
                     Rule(host: "rest-only-media.example", category: .entertainment)]
        preferences.rules = rules
        let work = Foreground(token: "work", classification: Rule.classify(ActivityIdentity(appID: "chrome", appName: "Chrome",
            window: "sensitive-window-title", host: "work.example", path: "/projects/private-token"), using: rules))
        let media = Foreground(token: "video", classification: Rule.classify(ActivityIdentity(appID: "unique-rest-player",
            appName: "Rest video", host: "rest-only-media.example", path: "/secret"), using: rules))
        let unknown = Foreground(token: "unknown", classification: Rule.classify(ActivityIdentity(appID: "unknown-rest-only",
            appName: "Unknown"), using: []))
        var engine = TimeEngine(preferences: preferences, calendar: calendar)
        let start = noon.addingTimeInterval(-30)
        _ = engine.observe(at: start, Observation(foreground: work, input: start))
        let videoStart = noon.addingTimeInterval(30)
        let workSlices = engine.observe(at: videoStart, Observation(foreground: media, videoPlaying: true))
        let unknownStart = noon.addingTimeInterval(100)
        let ignored = engine.observe(at: unknownStart, Observation(foreground: unknown, input: unknownStart))
        let ending = engine.observe(at: noon.addingTimeInterval(150), Observation(suspended: true))
        do {
            let store = try SQLiteStore(path: path.path)
            try store.append(workSlices + ignored + ending)
            try store.append(workSlices)
        }

        let databaseBytes = try Data(contentsOf: path)
        for needle in ["sensitive-window-title", "private-token", "rest-only-media.example", "unique-rest-player", "unknown-rest-only"] {
            expect(databaseBytes.range(of: Data(needle.utf8)) == nil)
        }
        let store = try SQLiteStore(path: path.path)
        let firstReport = try store.report(day: day)
        expect(firstReport.entries.count == 2)
        expect(firstReport.entries[0].basis == .path)
        expect(firstReport.entries[0].timeZoneID == "Asia/Singapore")
        expect(firstReport.total(.regular) == 30)
        expect(firstReport.total(.overtime) == 30)
        expect(firstReport.total(.entertainment) == 0)
        expect(firstReport.entries.last?.restReason == "周排班 12:00–13:00")
        var future = preferences
        future.rules.append(Rule(host: "work.example", pathPrefix: "/projects", category: .entertainment))
        try store.correct(entry: firstReport.entries[0], to: .entertainment, saving: future)
        expect(try store.preferences() == future)
        expect(try store.report(day: day).total(.entertainment) == 30)
        expect(try store.report(day: day).entries.first?.corrected == true)
        try store.correct(entry: firstReport.entries[1], to: .unclassified)
        expect(try store.report(day: day).entries.count == 1)
        expect(try store.report(day: day).total(.overtime) == 0)
    }

    func testCheckpointsMergeOnlyContiguousSpans() throws {
        let store = try SQLiteStore(path: ":memory:")
        let initialPreferences = try store.preferences()
        expect(try store.preferences() == initialPreferences)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var engine = TimeEngine(calendar: calendar)
        let start = Date(timeIntervalSince1970: 1000)
        let identity = ActivityIdentity(appID: "com.apple.Terminal", appName: "Terminal")
        let front = Foreground(token: "terminal", classification: Rule.classify(identity, using: Preferences().rules))
        _ = engine.observe(at: start, Observation(foreground: front, input: start))
        try store.append(engine.observe(at: start.addingTimeInterval(10), Observation(foreground: front)))
        try store.append(engine.observe(at: start.addingTimeInterval(15), Observation(suspended: true)))
        let restart = start.addingTimeInterval(1000)
        var restarted = TimeEngine(calendar: calendar)
        expect(restarted.observe(at: restart, Observation(foreground: front, input: start)).isEmpty)
        _ = restarted.observe(at: restart, Observation(foreground: front, input: restart))
        let last = restarted.observe(at: restart.addingTimeInterval(5), Observation(foreground: front))
        try store.append(last)
        try store.append(last)
        let report = try store.report(day: Schedule.dayKey(start, calendar: calendar))
        expect(report.entries.map(\.duration) == [15, 5])
        expect(report.total(.regular) == 20)
    }

    func testHistoricalAutomaticClassificationPreservesOverrides() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.sqlite3").path
        _ = try SQLiteStore(path: file)
        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        seed.arguments = [file, """
            DROP VIEW reported_slice;
            CREATE VIEW reported_slice AS SELECT id, 'entertainment' AS bucket FROM slice;
            INSERT INTO slice(start,end,day,time_zone,span,category,bucket,app_id,app_name,kind,basis,corrected)
            VALUES (100,110,'2026-11-25','UTC','a','unclassified','review','com.netease.163music','Music','interactive','none',0),
                   (110,120,'2026-11-25','UTC','b','unclassified','review','com.netease.163music','Music','interactive','none',1),
                   (120,130,'2026-11-25','UTC','c','unclassified','review','com.netease.163music','Music','interactive','app',0),
                   (130,140,'2026-11-25','UTC','d','unclassified','review','com.microsoft.edgemac','Edge','interactive','none',0),
                   (140,150,'2026-11-25','UTC','e','unclassified','review','com.google.Chrome','Chrome','interactive','browserDisconnected',0),
                   (150,160,'2026-11-25','UTC','f','unclassified','review','com.microsoft.edgemac','Edge','interactive','browserPageUnavailable',0),
                   (160,170,'2026-11-25','UTC','g','work','regular','com.microsoft.edgemac','Edge','interactive','app',0),
                   (170,180,'2026-11-25','UTC','h','entertainment','entertainment','com.google.Chrome','Chrome','interactive','app',1);
            INSERT INTO slice(start,end,day,time_zone,span,category,bucket,app_id,app_name,host,kind,basis)
            VALUES (180,190,'2026-11-25','UTC','i','unclassified','review','com.google.Chrome','Chrome','unknown.example','interactive','none');
            """]
        try seed.run()
        seed.waitUntilExit()
        expect(seed.terminationStatus == 0)
        let store = try SQLiteStore(path: file)
        try store.classifyExistingUnknownSources()
        try store.classifyExistingUnknownSources()
        let rows = try store.report(day: "2026-11-25").entries
        expect(rows.map(\.bucket) == [.entertainment, .entertainment, .entertainment, .review, .review,
                                       .review, .regular, .entertainment, .entertainment])
        expect(rows.map(\.basis) == [.automaticApp, .none, .app, .none, .browserDisconnected,
                                      .browserPageUnavailable, .app, .app, .none])
        let total = try store.totals(from: "2026-11-25", through: "2026-11-25")
        expect(total.count == 3 && total.first(where: { $0.bucket == .entertainment })?.duration == 50)
        expect(total.first(where: { $0.bucket == .review })?.duration == 30)
        let grouped = try store.sourceTotals(from: "2026-11-25", through: "2026-11-25", bucket: .entertainment)
        expect(grouped.map(\.count) == [3, 1, 1])
        let detail = try store.report(from: "2026-11-25", through: "2026-11-25", bucket: .entertainment)
        expect(detail.entries.count == 5)
        expect(rows.count == 9 && rows.allSatisfy { $0.duration == 10 })
        expect(rows.first?.basis == .automaticApp)
        expect(rows[1].corrected)
        try store.correct(entry: rows[3], to: .work)
        let corrected = try store.report(day: "2026-11-25")
        expect(corrected.total(.regular) == 20 && corrected.total(.review) == 20)
    }

    func testSavedScheduleDoesNotRecategorizeExistingTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.sqlite3").path
        let store = try SQLiteStore(path: file)
        var prefs = try store.preferences()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12))!
        let day = Schedule.dayKey(noon, calendar: calendar)
        var engine = TimeEngine(preferences: prefs, calendar: calendar)
        let editor = ActivityIdentity(appID: "com.apple.Terminal", appName: "Terminal")
        let work = Foreground(token: "editor", classification: Rule.classify(editor, using: prefs.rules))
        _ = engine.observe(at: noon, Observation(foreground: work, input: noon))
        let savedAt = noon.addingTimeInterval(30)
        try store.append(engine.observe(at: savedAt, Observation()))
        prefs.schedule.weekdays[4] = [RestPeriod(start: 720, end: 780)]
        prefs.schedule.overrides["2026-11-26"] = []
        try store.save(prefs)

        let reopened = try SQLiteStore(path: file)
        let settings = try reopened.preferences()
        expect(settings.schedule == prefs.schedule)
        engine.reconfigure(settings, calendar: calendar)
        _ = engine.observe(at: savedAt, Observation(foreground: work, input: savedAt))
        try reopened.append(engine.observe(at: savedAt.addingTimeInterval(25), Observation()))
        let report = try reopened.report(day: day)
        expect(report.entries.map(\.duration) == [30, 25])
        expect(report.entries.map(\.bucket) == [.regular, .overtime])
        expect(report.entries.last?.restReason == "周排班 12:00–13:00")
    }

    func testReportRangeTotalsPagingAndSources() throws {
        let store = try SQLiteStore(path: ":memory:")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        var preferences = Preferences()
        preferences.rules = [
            Rule(appID: "editor", category: .work),
            Rule(host: "media.example", category: .entertainment)
        ]
        let editor = ActivityIdentity(appID: "editor", appName: "Editor")
        let theater = ActivityIdentity(appID: "chrome", appName: "Chrome", host: "media.example")
        let rules = preferences.rules
        var engine = TimeEngine(preferences: preferences, calendar: calendar)
        let dates = [(2025, 12, 31), (2026, 1, 1), (2026, 1, 2)]
        for (index, (year, month, day)) in dates.enumerated() {
            let start = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 10))!
            let product = index.isMultiple(of: 2) ? editor : theater
            let front = Foreground(token: product.appID, classification: Rule.classify(product, using: rules))
            _ = engine.observe(at: start, Observation(foreground: front, input: start))
            try store.append(engine.observe(at: start.addingTimeInterval(Double((index + 1) * 20)), Observation()))
        }
        let first = "2025-12-31"
        let last = "2026-01-02"
        let rows = try store.report(from: first, through: last).entries
        expect(rows.map(\.day) == [first, "2026-01-01", last])
        let totals = try store.totals(from: first, through: last)
        expect(totals.map(\.duration) == [20, 40, 60])
        expect(totals.reduce(0) { $0 + $1.count } == rows.count)
        expect(try store.totals(from: "2026-01-01", through: "2026-01-31").map(\.duration) == [40, 60])
        let page = try store.report(from: first, through: last, bucket: .regular, limit: 1, offset: 1)
        expect(page.entries.map(\.day) == [last])
        let newest = try store.report(from: first, through: last, limit: 1, newestFirst: true)
        expect(newest.entries.map(\.day) == [last])
        let sources = try store.sourceTotals(from: first, through: last, bucket: nil)
        expect(sources.map(\.label) == ["Editor", "media.example"])
        expect(sources.map(\.duration) == [80, 40])
        expect(sources.map(\.count) == [2, 1])
        let sourceRows = try store.report(from: first, through: last, source: sources[1].id)
        expect(sourceRows.entries.map(\.bucket) == [.entertainment])
    }


    func testMixedSiteShowsWorkEntertainmentAndReview() throws {
        let store = try SQLiteStore(path: ":memory:")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 11))!
        let day = Schedule.dayKey(start, calendar: calendar)
        var preferences = Preferences()
        preferences.schedule.overrides[day] = [RestPeriod(start: 12 * 60, end: 13 * 60)]
        preferences.rules = [
            Rule(host: "portal.example", pathPrefix: "/work", project: "atlas", category: .work),
            Rule(host: "portal.example", pathPrefix: "/watch", category: .entertainment)
        ]
        var engine = TimeEngine(preferences: preferences, calendar: calendar)
        let visits = [(0, "/work/atlas"), (180, "/watch/runtime"), (360, "/home"), (3_600, "/work/atlas")]
        for (offset, path) in visits {
            let time = start.addingTimeInterval(Double(offset))
            let page = ActivityIdentity(appID: "chrome", appName: "Chrome", host: "portal.example", path: path)
            let front = Foreground(token: path, classification: Rule.classify(page, using: preferences.rules))
            _ = engine.observe(at: time, Observation(foreground: front, input: time))
            try store.append(engine.observe(at: time.addingTimeInterval(60), Observation()))
        }
        let sources = try store.sourceBreakdown(from: day, through: day)
        expect(sources.count == 1)
        let site = sources.first
        expect(site?.isMixed == true)
        expect(site?.work == 120)
        expect(site?.entertainment == 120)
        expect(site?.byBucket[.review] == nil)
        expect(site?.byBucket[.overtime] == 60)
        expect(site?.total.count == 4)
    }

    func testWebsiteVisitsAcrossBrowsersAndLegacyMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.sqlite3")
        _ = try SQLiteStore(path: file.path)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 26))!
        let start = midnight.addingTimeInterval(-5)
        let first = Schedule.dayKey(start, calendar: calendar)
        let second = Schedule.dayKey(midnight, calendar: calendar)
        let legacy = Process()
        legacy.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        legacy.arguments = [file.path, """
            DROP INDEX slice_website_day;
            ALTER TABLE slice DROP COLUMN visit_id;
            INSERT INTO slice(start,end,day,time_zone,span,category,bucket,app_id,app_name,host,kind,basis)
            VALUES (\(start.timeIntervalSince1970 - 30),\(start.timeIntervalSince1970 - 25),'\(first)','UTC',
                    'old','work','regular','com.google.Chrome','Chrome','site.example','interactive','domain');
            """]
        try legacy.run()
        legacy.waitUntilExit()
        expect(legacy.terminationStatus == 0)
        let store = try SQLiteStore(path: file.path)
        var preferences = Preferences()
        preferences.idleSeconds = 10
        preferences.schedule.overrides[second] = [RestPeriod(start: 0, end: 1)]
        preferences.rules = [Rule(host: "site.example", pathPrefix: "/work", category: .work)]
        var engine = TimeEngine(preferences: preferences, calendar: calendar)
        let work = Foreground(token: "private-tab-1", classification: Rule.classify(ActivityIdentity(
            appID: "com.google.Chrome", appName: "Chrome", host: "site.example", path: "/work"), using: preferences.rules))
        let personal = Foreground(token: "private-tab-2", classification: Rule.classify(ActivityIdentity(
            appID: "com.microsoft.edgemac", appName: "Edge", host: "site.example", path: "/personal"), using: preferences.rules))
        let restOnly = Foreground(token: "private-tab-3", classification: Rule.classify(ActivityIdentity(
            appID: "com.microsoft.edgemac", appName: "Edge", host: "rest-only.example"), using: []))
        let events: [(offset: Double, focus: Foreground?, input: Bool)] = [
            (0, work, true), (5, work, false), (10, work, false), (13, work, false), (15, work, true),
            (20, restOnly, true), (35, nil, false), (70, personal, true), (76, work, true), (79, nil, false)
        ]
        for event in events {
            let date = start.addingTimeInterval(event.offset)
            let slices = engine.observe(at: date, Observation(foreground: event.focus, input: event.input ? date : nil))
            try store.append(slices)
            try store.append(slices)
        }

        let sites = try store.websiteTotals(from: first, through: second)
        expect(sites.map(\.id) == ["site.example"])
        let site = sites.first
        expect(site?.visits == 3 && site?.hasEarlierFragments == true)
        expect(site?.work == 23 && site?.entertainment == 6 && site?.duration == 29)
        expect(try store.websiteTotals(from: first, through: first).first?.visits == 1)
        expect(try store.websiteTotals(from: second, through: second).first?.visits == 3)
        let rows = try store.report(from: first, through: second, source: .website("site.example")).entries
        expect(Set(rows.map(\.appID)) == ["com.google.Chrome", "com.microsoft.edgemac"])
        expect(rows.reduce(0) { $0 + $1.duration } == site?.duration)
        let bytes = try Data(contentsOf: file)
        expect(bytes.range(of: Data("private-tab".utf8)) == nil)
        expect(bytes.range(of: Data("rest-only.example".utf8)) == nil)
        let reopened = try SQLiteStore(path: file.path)
        expect(try reopened.websiteTotals(from: first, through: second).first?.visits == 3)
    }

}
