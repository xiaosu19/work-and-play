import Foundation
import TimeCore

final class TimeEngineTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return calendar
    }

    private var noon: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12))! }

    private func front(_ id: String, _ category: ActivityCategory, _ kind: ActivityKind = .interactive) -> Foreground {
        Foreground(token: id, classification: Rule.classify(ActivityIdentity(appID: id, appName: id),
            using: [Rule(appID: id, category: category, kind: kind)]))
    }

    func testReadingExampleAndDuplicate() {
        var engine = TimeEngine(calendar: calendar)
        let document = front("doc", .work, .reading)
        let pageTurn = noon.addingTimeInterval(90)
        let later = pageTurn.addingTimeInterval(3600)
        expect(engine.observe(at: noon, Observation(foreground: document, reading: noon)).isEmpty)
        var slices = engine.observe(at: pageTurn, Observation(foreground: document, reading: pageTurn))
        expect(engine.observe(at: pageTurn, Observation(foreground: document, reading: pageTurn)).isEmpty)
        slices += engine.observe(at: later, Observation(foreground: document, input: later, reading: pageTurn))
        expect(slices.map(\.duration) == [90, 120])
        expect(slices.reduce(0) { $0 + $1.duration } == 210)
        expect(!engine.active(at: later))
    }

    func testLunchExampleAndRestPrivacy() {
        var prefs = Preferences()
        prefs.schedule.weekdays[4] = [RestPeriod(start: 720, end: 780)]
        prefs.countVideo = true
        var engine = TimeEngine(preferences: prefs, calendar: calendar)
        var slices: [TimeSlice] = []
        let work = front("editor", .work)
        for offset in stride(from: -600, to: 600, by: 100) {
            let now = noon.addingTimeInterval(Double(offset))
            slices += engine.observe(at: now, Observation(foreground: work, input: now))
        }
        let leisure = noon.addingTimeInterval(600)
        let unknown = noon.addingTimeInterval(900)
        slices += engine.observe(at: leisure, Observation(foreground: front("player", .entertainment), videoPlaying: true))
        slices += engine.observe(at: unknown, Observation(foreground: front("unknown", .unclassified), input: unknown))
        slices += engine.observe(at: noon.addingTimeInterval(3600), Observation())
        expect(slices.filter { $0.bucket == .regular }.reduce(0) { $0 + $1.duration } == 600)
        expect(slices.filter { $0.bucket == .overtime }.reduce(0) { $0 + $1.duration } == 600)
        expect(slices.allSatisfy { $0.activity.category == .work })
    }

    func testForegroundVideoAndNoCreditAfterSwitch() {
        var prefs = Preferences()
        prefs.countVideo = true
        var engine = TimeEngine(preferences: prefs, calendar: calendar)
        let player = front("youtube-tab-1", .entertainment)
        let other = front("youtube-tab-2", .entertainment)
        _ = engine.observe(at: noon, Observation(foreground: player, videoPlaying: true))
        let switchTime = noon.addingTimeInterval(300)
        let slices = engine.observe(at: switchTime, Observation(foreground: other))
        expect(slices.map(\.duration) == [300])
        expect(engine.observe(at: switchTime.addingTimeInterval(600), Observation(foreground: other)).isEmpty)
    }

    func testIdleResumesOnlyOnNewInputAndPauseStopsVideo() {
        var prefs = Preferences()
        prefs.countVideo = true
        var engine = TimeEngine(preferences: prefs, calendar: calendar)
        let activity = front("app", .work)
        _ = engine.observe(at: noon, Observation(foreground: activity, input: noon))
        let expiry = noon.addingTimeInterval(400)
        expect(engine.observe(at: expiry, Observation(foreground: activity, input: noon)).map(\.duration) == [180])
        let resume = expiry.addingTimeInterval(20)
        expect(engine.observe(at: resume, Observation(foreground: activity, input: resume)).isEmpty)
        let player = front("video", .entertainment)
        let videoStart = resume.addingTimeInterval(12)
        expect(engine.observe(at: videoStart, Observation(foreground: player, videoPlaying: true)).map(\.duration) == [12])
        let pause = videoStart.addingTimeInterval(20)
        expect(engine.observe(at: pause, Observation(foreground: player, input: pause)).map(\.duration) == [20])
        expect(engine.observe(at: pause.addingTimeInterval(60), Observation(foreground: player)).isEmpty)
    }

    func testMidnightOverrideAndBoundaryDoesNotRenew() {
        var prefs = Preferences()
        prefs.schedule.weekdays[5] = [RestPeriod(start: 0, end: 1440)]
        prefs.schedule.overrides["2026-11-26"] = [RestPeriod(start: 0, end: 1)]
        let work = front("terminal", .work)
        var engine = TimeEngine(preferences: prefs, calendar: calendar)
        let midnight = noon.addingTimeInterval(43200)
        let start = midnight.addingTimeInterval(-30)
        _ = engine.observe(at: start, Observation(foreground: work, input: start))
        let slices = engine.observe(at: midnight.addingTimeInterval(360), Observation(foreground: work))
        expect(slices.map(\.duration) == [30, 60, 90])
        expect(slices.map(\.bucket) == [.regular, .overtime, .regular])
        expect(slices.map(\.day) == ["2026-11-25", "2026-11-26", "2026-11-26"])
        expect(slices[1].restReason == "日期覆盖 00:00–00:01")
    }

    func testEffectiveRestPlanAndEmptyDateOverride() {
        let lunch = RestPeriod(start: 720, end: 780)
        let evening = RestPeriod(start: 1080, end: 1440)
        var schedule = Schedule(weekdays: [4: [evening, lunch]])
        let day = Schedule.dayKey(noon, calendar: calendar)
        expect(schedule.plan(for: noon, calendar: calendar).periods == [lunch, evening])
        expect(!schedule.plan(for: noon, calendar: calendar).isOverride)
        expect(schedule.activeRestPeriod(at: noon.addingTimeInterval(-0.25), calendar: calendar) == nil)
        expect(schedule.activeRestPeriod(at: noon, calendar: calendar) == lunch)
        expect(schedule.activeRestPeriod(at: noon.addingTimeInterval(3600), calendar: calendar) == nil)
        expect(schedule.activeRestPeriod(at: noon.addingTimeInterval(43200), calendar: calendar) == nil)
        expect(schedule.activeBucket(for: .work, at: noon, calendar: calendar) == .overtime)
        expect(schedule.activeBucket(for: .entertainment, at: noon, calendar: calendar) == nil)
        schedule.overrides[day] = []
        expect(schedule.plan(for: noon, calendar: calendar).isOverride)
        expect(schedule.plan(for: noon, calendar: calendar).periods.isEmpty)
        expect(schedule.activeBucket(for: .work, at: noon, calendar: calendar) == .regular)
        schedule.overrides.removeValue(forKey: day)
        expect(schedule.activeRestPeriod(at: noon, calendar: calendar) == lunch)
    }

    func testWorkdaySetupWithLunchAndDailyBoundaries() {
        let hours = WorkdayHours(start: 9 * 60, end: 18 * 60, lunch: RestPeriod(start: 700, end: 810))!
        expect(hours.ordinaryPeriods.map(\.description) == ["09:00–11:40", "13:30–18:00"])
        expect(hours.ordinaryPeriods.reduce(0) { $0 + $1.end - $1.start } == 430)
        expect(hours.restPeriods.map(\.description) == ["00:00–09:00", "11:40–13:30", "18:00–24:00"])
        expect(WorkdayHours(restPeriods: hours.restPeriods) == hours)
        let schedule = Schedule(weekdays: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, hours.restPeriods) }))
        let cases: [(Int, Bucket)] = [(539, .overtime), (540, .regular), (699, .regular), (700, .overtime),
                                      (809, .overtime), (810, .regular), (1079, .regular), (1080, .overtime)]
        for offset in 0..<7 {
            let date = calendar.date(byAdding: .day, value: offset, to: noon)!
            let dayStart = calendar.startOfDay(for: date)
            expect(schedule.plan(for: date, calendar: calendar).periods == hours.restPeriods)
            for (minute, bucket) in cases {
                let time = dayStart.addingTimeInterval(Double(minute) * 60)
                expect(schedule.activeBucket(for: .work, at: time, calendar: calendar) == bucket)
                expect(schedule.activeBucket(for: .entertainment, at: time, calendar: calendar)
                       == (bucket == .regular ? .entertainment : nil))
            }
        }
    }

    func testWorkdayClockEntryAndValidation() {
        for text in ["11:40", "11.40", "１１：４０", "1140"] {
            expect(WorkdayHours.minute(from: text) == 700)
        }
        expect(WorkdayHours.minute(from: "9") == 540)
        expect(WorkdayHours.minute(from: "24:00") == nil)
        expect(WorkdayHours.minute(from: "24:00", allowEndOfDay: true) == 1440)
        expect(WorkdayHours.minute(from: "24:01", allowEndOfDay: true) == nil)
        for invalid in ["", "00:60", "9:4", "-9", "13::30", "abc", "99"] {
            expect(WorkdayHours.minute(from: invalid) == nil)
        }
        expect(WorkdayHours(start: 540, end: 1080, lunch: RestPeriod(start: 700, end: 90)) == nil)
        expect(WorkdayHours(start: 540, end: 360, lunch: nil) == nil)
        expect(WorkdayHours(start: 540, end: 1080, lunch: nil)?.restPeriods.map(\.description) ==
               ["00:00–09:00", "18:00–24:00"])
        expect(WorkdayHours(restPeriods: [RestPeriod(start: 0, end: 1440)]) == nil)
    }

    func testLockSleepRestartAndOldSignals() {
        var engine = TimeEngine(calendar: calendar)
        let work = front("terminal", .work)
        _ = engine.observe(at: noon, Observation(foreground: work, input: noon))
        let lock = noon.addingTimeInterval(25)
        expect(engine.observe(at: lock, Observation(suspended: true)).map(\.duration) == [25])
        expect(engine.observe(at: lock, Observation(suspended: true)).isEmpty)
        let wake = lock.addingTimeInterval(500)
        expect(engine.observe(at: wake, Observation(foreground: work, input: noon)).isEmpty)
        expect(!engine.active(at: wake))
        _ = engine.observe(at: wake, Observation(foreground: work, input: wake))
        engine.discardCoverage()
        expect(engine.observe(at: wake.addingTimeInterval(100), Observation(foreground: work)).isEmpty)
        var restarted = TimeEngine(calendar: calendar)
        expect(restarted.observe(at: wake.addingTimeInterval(1000), Observation(foreground: work, input: wake)).isEmpty)
        expect(!restarted.active(at: wake.addingTimeInterval(1000)))
    }

    func testVideoCannotExtendWorkAndAudioDoesNotRenewReading() {
        var prefs = Preferences()
        prefs.countVideo = true
        var engine = TimeEngine(preferences: prefs, calendar: calendar)
        let document = front("doc", .work, .reading)
        _ = engine.observe(at: noon, Observation(foreground: document, reading: noon))
        let playingButWork = noon.addingTimeInterval(300)
        let reading = engine.observe(at: playingButWork, Observation(foreground: document, videoPlaying: true))
        expect(reading.map(\.duration) == [120])
        expect(!engine.active(at: playingButWork))
        let player = front("audio", .entertainment)
        _ = engine.observe(at: playingButWork, Observation(foreground: player, input: playingButWork))
        let later = playingButWork.addingTimeInterval(500)
        expect(engine.observe(at: later, Observation(foreground: player)).map(\.duration) == [180])
        expect(!engine.active(at: later))
    }

    func testAutomaticClassificationUsesAppMetadataAndLiveContext() {
        func classify(_ app: String, window: String? = nil, host: String? = nil, path: String? = nil,
                      appCategory: String? = nil, rules: [Rule] = []) -> Classification {
            Rule.classify(ActivityIdentity(appID: app, appName: app, window: window, host: host,
                                           path: path, appCategory: appCategory), using: rules)
        }

        expect(classify("com.netease.163music").category == .entertainment)
        expect(classify("com.apple.QuickTimePlayerX").basis == .automaticApp)
        expect(classify("com.kingsoft.wpsoffice.mac").category == .work)
        expect(classify("abnerworks.Typora").category == .work)
        expect(classify("test.game", appCategory: "public.app-category.strategy-games").category == .entertainment)
        expect(classify("test.ide", appCategory: "public.app-category.developer-tools").category == .work)
        expect(classify("test.music", appCategory: "public.app-category.music").category == .unclassified)
        let edge = "com.microsoft.edgemac"
        expect(classify(edge).category == .unclassified)
        let missingPage = ActivityIdentity(appID: edge, appName: "Edge")
        expect(Rule.classify(missingPage, using: [], fallbackBasis: .browserDisconnected).basis == .browserDisconnected)
        let edgeRule = Rule(appID: edge, category: .work)
        expect(Rule.classify(missingPage, using: [edgeRule], fallbackBasis: .browserPageUnavailable).basis == .app)
        expect(classify("com.openai.codex").category == .work)
        expect(classify("com.openai.chat").category == .work)
        expect(classify(edge, host: "chatgpt.com").basis == .automaticDomain)
        expect(classify(edge, host: "chat.openai.com").category == .work)
        expect(classify(edge, host: "developers.openai.com").kind == .reading)
        expect(classify(edge, host: "not-chatgpt.com").category == .unclassified)
        let personalGPT = Rule(host: "chatgpt.com", category: .entertainment)
        expect(classify(edge, host: "chatgpt.com", rules: [personalGPT]).category == .entertainment)
        expect(classify(edge, host: "docs.python.org").kind == .reading)
        expect(classify(edge, host: "fake-netflix.com").category == .unclassified)
        expect(classify(edge, host: "www.youtube.com", path: "/watch").category == .entertainment)
        expect(classify(edge, host: "www.youtube.com", path: "/upload").basis == .automaticPath)
        expect(classify(edge, host: "www.youtube.com", path: "/upload").category == .work)
        let rule = Rule(host: "www.youtube.com", pathPrefix: "/watch", category: .work)
        expect(classify(edge, host: "www.youtube.com", path: "/watch", rules: [rule]).basis == .path)

        let wechat = "com.tencent.xinWeChat"
        let ambiguous = classify(wechat, window: "同事群讨论视频号")
        let video = classify(wechat, window: "视频号")
        expect(ambiguous.category == .unclassified)
        expect(video.category == .entertainment)
        expect(video.basis == .automaticWindow)

        var engine = TimeEngine(calendar: calendar)
        let initial = Foreground(token: "same-window", classification: ambiguous)
        let changed = Foreground(token: "same-window", classification: video)
        _ = engine.observe(at: noon, Observation(foreground: initial, input: noon))
        let switched = noon.addingTimeInterval(15)
        let earlier = engine.observe(at: switched, Observation(foreground: changed, input: switched))
        expect(earlier.map(\.bucket) == [.review])
        let later = engine.observe(at: switched.addingTimeInterval(30), Observation())
        expect(later.map(\.bucket) == [.entertainment])
        expect(later.map(\.duration) == [30])
    }

    func testWildcardWebsiteMatchingAndPrecedence() throws {
        let browsers = ["com.google.Chrome", "com.microsoft.edgemac"]
        func result(_ host: String?, in browser: String = "com.microsoft.edgemac", path: String? = nil,
                    rules: [Rule]) -> Classification {
            Rule.classify(ActivityIdentity(appID: browser, appName: browser, host: host, path: path), using: rules)
        }

        for syntax in ["*.example.com", "*EXAMPLE.COM"] {
            let wildcard = Rule(host: syntax, category: .work)
            let saved = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(wildcard))
            expect(saved.valid && saved.isWebsiteOnly)
            for browser in browsers {
                for host in ["example.com", "docs.example.com", "preview.Docs.Example.Com"] {
                    expect(result(host, in: browser, rules: [saved]).ruleID == saved.id)
                }
            }
            for host in ["fakeexample.com", "example.com.invalid", "docs-example.com"] {
                expect(result(host, rules: [saved]).ruleID == nil)
            }
            expect(result(nil, rules: [saved]).ruleID == nil)
        }

        for pattern in ["*", "*.", "**example.com", "*..example.com", "*.example..com", "example.*",
                        "https://*.example.com", "*.example.com/path"] {
            expect(!Rule(appID: browsers[0], host: pattern, category: .work).valid)
        }

        let allApps = Rule(host: "*.example.com", category: .work)
        let narrower = Rule(host: "*docs.example.com", category: .entertainment)
        let exact = Rule(host: "docs.example.com", category: .entertainment)
        let directory = Rule(host: "*.example.com", pathPrefix: "/projects", category: .work)
        let rules = [exact, narrower, directory, allApps]
        expect(result("docs.example.com", rules: rules).ruleID == exact.id)
        expect(result("preview.docs.example.com", rules: rules).ruleID == narrower.id)
        expect(result("docs.example.com", path: "/projects/inbox", rules: rules).ruleID == directory.id)
        expect(result("docs.example.com", path: "/projects-preview", rules: rules).ruleID == exact.id)
        expect(!directory.isWebsiteOnly)

        let misconfigured = Rule(appID: "example", host: "docs.example.com", category: .entertainment)
        let websiteOnly = Rule(host: "docs.example.com", category: .work)
        expect(!misconfigured.isWebsiteOnly)
        for browser in browsers {
            expect(result("docs.example.com", in: browser, rules: [websiteOnly, misconfigured]).ruleID == websiteOnly.id)
        }
    }

    func testDaylightSavingUsesElapsedHours() {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let days = [(3, 8, 23), (11, 1, 25)]
        for (month, day, hours) in days {
            let start = local.date(from: DateComponents(year: 2026, month: month, day: day))!
            let dayRange = local.dateInterval(of: .day, for: start)!
            var prefs = Preferences()
            prefs.schedule.weekdays[1] = [RestPeriod(start: 0, end: 1440)]
            let work = front("editor", .work)
            var engine = TimeEngine(preferences: prefs, calendar: local)
            var slices: [TimeSlice] = []
            for offset in stride(from: 0, to: hours * 3600, by: 120) {
                let sample = start.addingTimeInterval(Double(offset))
                slices += engine.observe(at: sample, Observation(foreground: work, input: sample))
            }
            slices += engine.observe(at: dayRange.end, Observation())
            expect(slices.allSatisfy { $0.bucket == .overtime })
            expect(slices.reduce(0) { $0 + $1.duration } == Double(hours * 3600))
        }
    }

    func testBrowserLeaseAndSpecificRule() {
        let rules = [
            Rule(appID: "chrome", category: .unclassified),
            Rule(host: "example.com", category: .entertainment),
            Rule(host: "example.com", pathPrefix: "/projects", category: .work, kind: .reading),
            Rule(host: "example.com", pathPrefix: "/projects/atlas", category: .entertainment),
            Rule(appID: "editor", windowContains: "Workspace", project: "Atlas", category: .work)
        ]
        let identity = ActivityIdentity(appID: "chrome", appName: "Chrome", host: "example.com", path: "/projects/atlas-notes")
        let classified = Rule.classify(identity, using: rules)
        expect(classified.category == .work)
        expect(classified.kind == .reading)
        expect(classified.label == "example.com")
        expect(Rule.classify(ActivityIdentity(appID: "editor", appName: "Editor", window: "Atlas Workspace"), using: rules).category == .work)
        let page = Foreground(token: "tab", classification: classified)
        var engine = TimeEngine(calendar: calendar)
        _ = engine.observe(at: noon, Observation(foreground: page, reading: noon, validUntil: noon.addingTimeInterval(3)))
        let fallback = front("chrome", .unclassified)
        expect(engine.observe(at: noon.addingTimeInterval(7), Observation(foreground: fallback)).map(\.duration) == [3])
    }
}
