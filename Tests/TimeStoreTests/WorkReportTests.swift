import Foundation
import TimeCore
import TimeStore

struct WorkReportTests {
    func activityAuthorizationRequiresSpecificWorkContext() {
        var site = WorkCaptureRule()
        site.target = "docs.example.test"
        site.detail = "/work"
        site.project = "测试项目"
        var focused = ActivityIdentity(appID: "com.google.Chrome", appName: "Chrome",
            host: "docs.example.test", path: "/work/guide")
        expect(WorkCaptureRule.authorized(through: [site], for: focused, category: .work) == site)
        expect(WorkCaptureRule.authorized(through: [site], for: focused, category: .entertainment) == nil)
        expect(WorkCaptureRule.authorized(through: [], for: focused, category: .work) == nil)
        focused.path = "/work-personal"
        expect(WorkCaptureRule.authorized(through: [site], for: focused, category: .work) == nil)

        var chat = WorkCaptureRule()
        chat.scope = .conversation
        chat.target = "com.tencent.xinWeChat"
        chat.detail = "客户测试会话"
        chat.project = "客户 A"
        var conversation = ActivityIdentity(appID: chat.target, appName: "微信", window: chat.detail)
        expect(chat.matches(conversation))
        conversation.window = "私人测试会话"
        expect(!chat.matches(conversation))
        chat.detail = "微信"
        expect(!chat.valid)
        chat.scope = .application
        chat.detail = ""
        expect(!chat.valid)
    }

    func workAndLeisureReportsStaySeparateAndCountOvertime() throws {
        let day = "2026-11-27"
        let dayPeriod = DigestPeriod(.day, including: day)!
        let weekPeriod = DigestPeriod(.week, including: day)!
        expect(weekPeriod.startDay == "2026-11-23" && weekPeriod.endDay == "2026-11-29")
        expect(DigestPeriod(.week, including: "2027-01-01")?.startDay == "2026-12-28")
        expect(DigestPeriod(.day, including: "2026-02-31") == nil)
        expect(DigestPeriod(.day, including: "../secret") == nil)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 12))!
        let store = try SQLiteStore(path: ":memory:")
        var prefs = Preferences()
        prefs.schedule.overrides[day] = [RestPeriod(start: 720, end: 721)]
        let workRule = Rule(appID: "test.work", category: .work)
        let leisureRule = Rule(appID: "test.fun", category: .entertainment)
        let work = Foreground(token: "work", classification: Rule.classify(
            ActivityIdentity(appID: "test.work", appName: "工作应用"), using: [workRule]))
        let leisure = Foreground(token: "fun", classification: Rule.classify(
            ActivityIdentity(appID: "test.fun", appName: "private-leisure-sentinel"), using: [leisureRule]))
        var engine = TimeEngine(preferences: prefs, calendar: calendar)
        let start = noon.addingTimeInterval(-30)
        _ = engine.observe(at: start, Observation(foreground: work, input: start))
        let firstSpan = engine.activeWorkSpan(at: start)!
        let endWork = noon.addingTimeInterval(30)
        let pending = engine.observe(at: endWork, Observation(foreground: leisure, input: endWork))
        let id = UUID()
        let at = start.addingTimeInterval(2)
        let attempted = WorkActivity(id: id, at: at, project: "项目甲", action: .submittedForm,
                                     result: .attempted, evidence: .trustedControl)
        let confirmed = WorkActivity(id: id, at: at, project: "项目甲", action: .submittedForm,
                                     result: .confirmed, evidence: .visibleFeedback)
        let invalid = WorkActivity(at: endWork.addingTimeInterval(2), project: "private-description-sentinel",
                                   action: .usedPage, result: .observed, evidence: .documentInteraction)
        let overtime = WorkActivity(at: noon.addingTimeInterval(10), project: "加班项目", action: .usedApplication,
                                    result: .observed, evidence: .foregroundInput)
        try store.append(pending, activities: [attempted, confirmed, attempted, invalid, overtime].map {
            PendingWorkActivity(spanID: firstSpan, activity: $0)
        })
        expect(engine.activeWorkSpan(at: endWork) == nil)
        try store.append(engine.observe(at: noon.addingTimeInterval(100), Observation()))

        let activities = try store.workActivities(from: day, through: day)
        expect(activities.count == 2)
        expect(activities.first?.activity.result == .confirmed)
        expect(activities.last?.activity.project == "加班项目")
        let totals = try store.totals(from: day, through: day)
        let report = WorkReportInput(period: weekPeriod, totals: totals, activities: activities)
        let workJSON = try WorkReportShare.json(report)
        expect(report.workSeconds == 60 && report.regularSeconds == 30 && report.overtimeSeconds == 30)
        expect(report.events.contains { $0.description == "提交「项目甲」表单成功" })
        expect(workJSON.range(of: Data("private-".utf8)) == nil)

        let leisureReport = LeisureReportInput(period: dayPeriod,
            sources: try store.sourceTotals(from: day, through: day, bucket: .entertainment))
        expect(leisureReport.leisureSeconds == 40)
        let leisureJSON = try WorkReportShare.json(leisureReport)
        expect(leisureJSON.range(of: Data("private-leisure-sentinel".utf8)) != nil)
        expect(leisureJSON.range(of: Data("项目甲".utf8)) == nil)
        expect(leisureJSON.range(of: Data("private-description-sentinel".utf8)) == nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        expect((try? WorkReportShare.read(.work, period: weekPeriod, in: root)) == nil)
        try WorkReportShare.publish(workJSON, channel: .work, period: weekPeriod, in: root)
        expect(try WorkReportShare.read(.work, period: weekPeriod, in: root) == workJSON)
        expect((try? WorkReportShare.read(.leisure, period: weekPeriod, in: root)) == nil)
        expect((try? WorkReportShare.publish(leisureJSON, channel: .work, period: dayPeriod, in: root)) == nil)
        expect((try? WorkReportShare.read(.work, period: weekPeriod, in: root,
            now: Date().addingTimeInterval(WorkReportShare.lifetime + 5))) == nil)
        try WorkReportShare.publish(leisureJSON, channel: .leisure, period: dayPeriod, in: root)
        expect(try WorkReportShare.read(.leisure, period: dayPeriod, in: root) == leisureJSON)
        try WorkReportShare.revokeCovering(day, channels: [.work], in: root)
        expect((try? WorkReportShare.read(.work, period: weekPeriod, in: root)) == nil)
        expect(try WorkReportShare.read(.leisure, period: dayPeriod, in: root) == leisureJSON)
        try WorkReportShare.revokeCovering(day, in: root)
        expect((try? WorkReportShare.read(.leisure, period: dayPeriod, in: root)) == nil)

        let regular = try store.report(day: day).entries.first!
        try store.addWorkNote(to: regular.id, project: "项目甲", note: "手动补记测试")
        try store.updateWorkActivity(id, note: "修正描述", excluded: true)
        let revised = try store.workActivities(from: day, through: day, segmentID: regular.id)
        expect(revised.count == 2)
        let revisedReport = WorkReportInput(period: dayPeriod, totals: totals, activities: revised)
        expect(revisedReport.events.count == 1 && revisedReport.events.first?.description == "手动补记测试")
        try store.correct(entry: regular, to: .entertainment)
        expect(try store.workActivities(from: day, through: day, segmentID: regular.id).isEmpty)
    }

    func automaticOperationJSONKeepsChannelsAndCorrectionsSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("archive")
        let path = root.appendingPathComponent("history.sqlite3").path
        let day = "2026-11-27"
        let week = DigestPeriod(.week, including: day)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 12))!
        var preferences = Preferences()
        preferences.schedule.overrides[day] = [RestPeriod(start: 720, end: 721)]
        let work = ActivityIdentity(appID: "test.work", appName: "工作测试", host: "work.example")
        let fun = ActivityIdentity(appID: "test.leisure", appName: "测试摸鱼", host: "leisure.example")
        let rules = [Rule(host: "work.example", category: .work, kind: .reading),
                     Rule(host: "leisure.example", category: .entertainment)]
        let working = Foreground(token: "work", classification: Rule.classify(work, using: rules))
        let relaxing = Foreground(token: "leisure", classification: Rule.classify(fun, using: rules))
        var engine = TimeEngine(preferences: preferences, calendar: calendar)
        let begin = noon.addingTimeInterval(-5.4)
        let switchToLeisure = noon.addingTimeInterval(30)
        _ = engine.observe(at: begin, Observation(foreground: working, reading: begin))
        let early = engine.observe(at: switchToLeisure, Observation(foreground: relaxing, input: switchToLeisure))
        let late = engine.observe(at: noon.addingTimeInterval(90), Observation())
        do {
            let store = try SQLiteStore(path: path)
            try store.append(early + late)
            let blocked = root.appendingPathComponent("blocked")
            try Data([0]).write(to: blocked)
            expect((try? store.syncOperationJSON(in: blocked)) == nil)
        }
        let store = try SQLiteStore(path: path)
        expect(try store.syncOperationJSON(in: archive) == 1)
        expect(try store.syncOperationJSON(in: archive) == 0)

        let workInput = try OperationJSON.readWork(week, in: archive)
        expect(workInput.days.map(\.period.startDay) == [day])
        expect(workInput.regularSeconds == 5 && workInput.overtimeSeconds == 30 && workInput.workSeconds == 35)
        expect(workInput.days.first?.events.isEmpty == true)
        expect(workInput.days.first?.segments?.map(\.bucket) == [.regular, .overtime])
        expect(workInput.days.first?.segments?.allSatisfy { $0.kind == .reading && $0.domain == "work.example" } == true)
        expect(try WorkReportShare.json(workInput).range(of: Data("leisure.example".utf8)) == nil)
        let leisureFile = OperationJSON.folder(for: .leisure, in: archive).appendingPathComponent(day + ".json")
        let leisure = try JSONDecoder().decode(LeisureReportInput.self, from: Data(contentsOf: leisureFile))
        expect(leisure.segments?.count == 1 && leisure.segments?.first?.seconds == 30)
        expect(leisure.segments?.first?.domain == "leisure.example")

        let first = try store.report(day: day).entries.first!
        try store.addWorkNote(to: first.id, project: "测试项目", note: "一次手动补记")
        expect(try store.syncOperationJSON(in: archive) == 1)
        let event = try OperationJSON.readWork(week, in: archive).days.first!.events.first!
        try store.updateWorkActivity(event.id, note: nil, excluded: true)
        expect(try store.syncOperationJSON(in: archive) == 1)
        expect(try OperationJSON.readWork(week, in: archive).days.first?.events.isEmpty == true)

        try OperationJSON.remove(day, channels: [.work], in: archive)
        expect((try? OperationJSON.readWork(week, in: archive)) == nil)
        try store.correct(entry: first, to: .entertainment)
        expect(try store.syncOperationJSON(in: archive) == 1)
        let corrected = try OperationJSON.readWork(week, in: archive)
        expect(corrected.workSeconds == 30 && corrected.days.first?.segments?.map(\.bucket) == [.overtime])
        expect(FileManager.default.fileExists(atPath: leisureFile.path))

        try store.correct(entry: try store.fragment(id: first.id)!, to: .work)
        let next = noon.addingTimeInterval(86_400)
        _ = engine.observe(at: next, Observation(foreground: working, reading: next))
        try store.append(engine.observe(at: next.addingTimeInterval(0.4), Observation()))
        expect(try store.syncOperationJSON(in: archive) == 2)
        let combinedWeek = try OperationJSON.readWork(week, in: archive)
        expect(combinedWeek.days.count == 2 && combinedWeek.regularSeconds == 6 && combinedWeek.workSeconds == 36)
    }
}
