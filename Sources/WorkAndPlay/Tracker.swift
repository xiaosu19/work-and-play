import AppKit
import ApplicationServices
import ChromeBridge
import Darwin
import Foundation
import OSLog
import TimeCore
import TimeStore

@MainActor
final class Tracker: ObservableObject {
    @Published private(set) var preferences = Preferences()
    @Published private(set) var status = "等待活动"
    @Published private(set) var precision = "应用级"
    @Published private(set) var browserConnections: Set<BrowserSource> = []
    @Published private(set) var accessibility = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var revision = 0

    private let log = Logger(subsystem: "local.workandplay", category: "runtime")
    private var store: SQLiteStore?
    private var engine = TimeEngine(calendar: Tracker.localCalendar)
    private var lock: Int32 = -1
    private var pending: [TimeSlice] = []
    private var timer: Timer?
    private var receiver: LocalBridge.Receiver?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var feeds: [BrowserSource: ChromeFeed] = [:]
    private var appCategories: [URL: String] = [:]
    private var input = DesktopInput()
    private var lastSample: (date: Date, uptime: Double)?
    private var lastFlushUptime: Double = 0
    private var lastSavedEnd: Date = .distantPast
    private var previousFocus: Foreground?
    private var interactionFloor = Date()
    private var browserOpening: Date?
    private var lastBrowserReading: Double = 0
    private var lastBrowserInput: Double = 0
    private var browserInputFloor = Date()
    private var currentPID: pid_t?
    private var systemSleeping = false
    private var screenSleeping = false
    private var sessionInactive = false
    private var screenLocked = false
    private var disposable = false

    nonisolated static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WorkAndPlay", isDirectory: true)

    func start() {
        guard timer == nil && !disposable else { return }
        do {
            let files = FileManager.default
            try files.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            let lockPath = Self.directory.appendingPathComponent("instance.lock").path
            lock = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                disposable = true
                NSApp.terminate(nil)
                return
            }
            let directory = ProcessInfo.processInfo.environment["WORKANDPLAY_DATA_DIRECTORY"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? Self.directory
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            let path = directory.appendingPathComponent("history.sqlite3").path
            let database = try SQLiteStore(path: path)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            preferences = try database.preferences()
            lastSavedEnd = try database.latestEnd() ?? .distantPast
            engine.reconfigure(preferences, calendar: Self.localCalendar)
            store = database
            do {
                try database.classifyExistingUnknownSources()
            } catch {
                log.error("Automatic classification of earlier activity could not complete")
            }
            revision += 1
        } catch {
            reportError("无法打开本机数据库。请检查工时簿目录的读写权限。")
        }

        receiver = LocalBridge.Receiver { [weak self] packet in
            let now = Date()
            guard let self, self.feeds[packet.source, default: ChromeFeed()].receive(packet, at: now) else { return }
            self.updateBrowserConnections(at: now)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == packet.source.rawValue { self.sample(at: now) }
        }
        installObservers()
        sample()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        log.notice("Tracker started")
    }

    func stop() {
        guard !disposable, timer != nil else { return }
        sample(forceSuspend: true)
        flush()
        timer?.invalidate()
        timer = nil
        receiver = nil
        for (center, token) in observers { center.removeObserver(token) }
        for token in distributedObservers { DistributedNotificationCenter.default().removeObserver(token) }
        log.notice("Tracker stopped")
    }

    func update(_ next: Preferences) -> Bool {
        guard let store else { return false }
        if next == preferences { return true }
        sample()
        guard flush() else { return false }
        do {
            try store.save(next)
            apply(next)
            return true
        } catch {
            reportError("无法保存设置。请检查本机数据库。")
            return false
        }
    }

    func togglePause() {
        var next = preferences
        next.paused.toggle()
        _ = update(next)
    }

    func report(dayRange: ClosedRange<String>, bucket: Bucket? = nil, source: ReportSource? = nil,
                limit: Int = -1, offset: Int = 0, newestFirst: Bool = false) -> DailyReport {
        (try? store?.report(from: dayRange.lowerBound, through: dayRange.upperBound, bucket: bucket,
                            source: source, limit: limit, offset: offset, newestFirst: newestFirst)) ?? DailyReport()
    }

    func totals(dayRange: ClosedRange<String>) -> [ReportTotal] {
        (try? store?.totals(from: dayRange.lowerBound, through: dayRange.upperBound)) ?? []
    }

    func sourceTotals(dayRange: ClosedRange<String>, bucket: Bucket?) -> [SourceTotal] {
        (try? store?.sourceTotals(from: dayRange.lowerBound, through: dayRange.upperBound, bucket: bucket)) ?? []
    }

    func sourceBreakdown(dayRange: ClosedRange<String>) -> [SourceBreakdown] {
        (try? store?.sourceBreakdown(from: dayRange.lowerBound, through: dayRange.upperBound)) ?? []
    }

    func websiteTotals(dayRange: ClosedRange<String>) -> [WebsiteTotal] {
        (try? store?.websiteTotals(from: dayRange.lowerBound, through: dayRange.upperBound)) ?? []
    }

    func suggestedRule(forWebsite host: String, category: ActivityCategory) -> Rule {
        let existing = preferences.rules.last { $0.isWebsiteOnly && $0.host.lowercased() == host }
        let defaultKind = Rule.classify(ActivityIdentity(appID: "", appName: host, host: host), using: []).kind
        var rule = existing ?? Rule(host: host, kind: defaultKind)
        rule.category = category
        return rule
    }

    func refreshReport() {
        sample()
        flush()
        revision += 1
    }

    func suggestedRule(for entry: ReportEntry) -> Rule {
        if var rule = preferences.rules.first(where: { $0.id == entry.ruleID }) {
            rule.id = UUID()
            rule.category = entry.category
            return rule
        }
        return Rule(appID: entry.appID, host: entry.host ?? "", category: entry.category, kind: entry.kind)
    }

    func correct(_ entry: ReportEntry, to category: ActivityCategory, futureRule: Rule?) -> Bool {
        guard let store, futureRule?.valid != false else { return false }
        sample()
        guard flush() else { return false }
        var next = preferences
        if let futureRule { next.rules.append(futureRule) }
        do {
            try store.correct(entry: entry, to: category, saving: futureRule == nil ? nil : next)
            // A correction seals the database row. A new observation starts any later history.
            apply(next)
            revision += 1
            return true
        } catch {
            reportError("无法保存片段修正。请重新打开日报后再试。")
            return false
        }
    }

    func openAccessibilityPrompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func apply(_ next: Preferences) {
        preferences = next
        engine.reconfigure(next, calendar: Self.localCalendar)
        resetInteraction(at: Date())
        if errorMessage != nil { errorMessage = nil }
        sample()
    }

    private func sample(at now: Date = Date(), forceSuspend: Bool = false) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let calendar = Self.localCalendar
        if let lastSample {
            let elapsed = now.timeIntervalSince(lastSample.date)
            if elapsed < 0 || elapsed > 4 || abs(elapsed - (uptime - lastSample.uptime)) > 1.5
                || calendar.timeZone != engine.calendar.timeZone {
                engine.reconfigure(preferences, calendar: calendar)
                feeds.removeAll()
                resetInteraction(at: now)
            }
        }
        lastSample = (now, uptime)
        updateBrowserConnections(at: now)
        let signals = input.sample(at: now)
        let app = NSWorkspace.shared.frontmostApplication
        let browser = app?.bundleIdentifier.flatMap(BrowserSource.init(rawValue:))
        let locked = Self.consoleLocked
        if forceSuspend || screenLocked || locked || screenSleeping || sessionInactive || systemSleeping
            || preferences.paused || now < lastSavedEnd {
            pending += engine.observe(at: now, Observation(suspended: true))
            resetInteraction(at: now)
            setStatus(preferences.paused ? "已暂停" : now < lastSavedEnd ? "等待系统时钟" : "采集已挂起", precision)
            flush()
            return
        }

        let ax = AXIsProcessTrusted()
        if ax != accessibility { accessibility = ax }
        guard let app, let appID = app.bundleIdentifier, appID != Bundle.main.bundleIdentifier,
              appID != "com.apple.loginwindow" else {
            pending += engine.observe(at: now, Observation())
            resetInteraction(at: now)
            setStatus("等待前台活动", precision)
            checkpoint(uptime)
            return
        }
        let appName = app.localizedName ?? appID
        let pid = app.processIdentifier
        if currentPID != pid {
            currentPID = pid
            browserOpening = nil
            browserInputFloor = now
            if let browser, let received = feeds[browser]?.receivedAt, received < now.addingTimeInterval(-0.5) {
                feeds.removeValue(forKey: browser)
            }
        }
        let window = DesktopWindow(process: pid)
        let feed = browser.flatMap { feeds[$0] }
        let usableFeed = feed?.isConnected(at: now) == true
        let page = usableFeed ? feed?.latest?.page : nil
        let identity = ActivityIdentity(appID: appID, appName: appName, window: window?.title,
                                        host: page.flatMap { Privacy.host($0.host) }, path: page?.path,
                                        appCategory: declaredCategory(of: app))
        let decision = Rule.classify(identity, using: preferences.rules)
        let token: String
        if let page {
            token = "\(pid)/\(page.tab)/\(page.document)/\(page.path)"
        } else {
            token = "\(pid)/\(window?.identifier ?? 0)"
        }
        let foreground = Foreground(token: token, classification: decision)
        let changed = previousFocus != foreground
        previousFocus = foreground
        var recentInput = signals.input.flatMap { $0 >= interactionFloor ? $0 : nil }
        var reading: Date?
        if browser != nil, let opening = signals.opening, opening >= interactionFloor { browserOpening = opening }
        if let page {
            if let timestamp = page.interactionAt, timestamp > lastBrowserInput {
                lastBrowserInput = timestamp
                let seen = Date(timeIntervalSince1970: timestamp / 1000)
                if seen >= browserInputFloor && seen <= now && now.timeIntervalSince(seen) <= ChromeFeed.lease {
                    recentInput = max(recentInput ?? seen, seen)
                }
            }
            if let timestamp = page.readingAt, timestamp > lastBrowserReading {
                lastBrowserReading = timestamp
                let seen = Date(timeIntervalSince1970: timestamp / 1000)
                if seen >= interactionFloor && abs(now.timeIntervalSince(seen)) <= 3 {
                    reading = changed ? now : min(now, seen)
                }
            }
            if changed, let opening = browserOpening, now.timeIntervalSince(opening) <= 2 {
                reading = now
                recentInput = now
                browserOpening = nil
            }
        } else {
            if let seen = (changed ? signals.opening : signals.reading), seen >= interactionFloor {
                reading = changed ? now : seen
            }
        }
        // A focus change opens at detection, so the switching input cannot backdate the new fragment.
        let validUntil = page == nil ? nil : feed?.receivedAt?.addingTimeInterval(ChromeFeed.lease)
        pending += engine.observe(at: now, Observation(foreground: foreground, input: recentInput.map { changed ? now : $0 },
            reading: reading, videoPlaying: page?.videoPlaying ?? false, validUntil: validUntil))
        let accuracy: String
        if let browser {
            if page != nil { accuracy = "\(browser.label) 页面级" }
            else { accuracy = usableFeed ? "应用级 · 当前网页未提供信号" : "应用级 · \(browser.label) 扩展未连接" }
        } else { accuracy = window?.title == nil ? "应用级" : "窗口级" }
        let bucket = preferences.schedule.activeBucket(for: decision.category, at: now, calendar: calendar)
        let activity: String
        if !engine.active(at: now) { activity = "等待互动" }
        else if let bucket { activity = "\(bucket.title) · \(decision.label)" }
        else { activity = "休息中" }
        setStatus(activity, accuracy)
        if changed { flush() } else { checkpoint(uptime) }
    }

    private func updateBrowserConnections(at now: Date) {
        let current = Set(feeds.compactMap { $0.value.isConnected(at: now) ? $0.key : nil })
        if current != browserConnections { browserConnections = current }
    }

    private func declaredCategory(of app: NSRunningApplication) -> String? {
        guard let url = app.bundleURL else { return nil }
        if let category = appCategories[url] { return category.isEmpty ? nil : category }
        let category = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        appCategories[url] = category ?? ""
        return category
    }

    private func resetInteraction(at now: Date) {
        previousFocus = nil
        currentPID = nil
        browserOpening = nil
        lastBrowserReading = 0
        lastBrowserInput = 0
        browserInputFloor = now
        interactionFloor = now
    }

    private func checkpoint(_ uptime: Double) {
        if uptime - lastFlushUptime >= 3 { flush() }
    }

    @discardableResult
    private func flush() -> Bool {
        lastFlushUptime = ProcessInfo.processInfo.systemUptime
        guard !pending.isEmpty else { return true }
        guard let store else { pending.removeAll(); return false }
        do {
            try store.append(pending)
            lastSavedEnd = max(lastSavedEnd, pending.last?.end ?? .distantPast)
            pending.removeAll(keepingCapacity: true)
            if errorMessage == "工时暂未写入本机数据库。工时簿会自动重试。" { errorMessage = nil }
            revision += 1
            return true
        } catch {
            if pending.count > 3600 { pending.removeFirst(pending.count - 3600) }
            reportError("工时暂未写入本机数据库。工时簿会自动重试。")
            return false
        }
    }

    private func reportError(_ message: String) {
        if errorMessage != message {
            errorMessage = message
            log.error("Local database operation failed")
        }
    }

    private func setStatus(_ value: String, _ accuracy: String) {
        let value = store == nil ? "数据库无法使用" : value
        if status != value { status = value }
        if precision != accuracy { precision = accuracy }
    }

    private static var consoleLocked: Bool {
        guard let state = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (state["CGSSessionScreenIsLocked"] as? Bool ?? false)
            || (state["kCGSessionOnConsoleKey"] as? Bool == false)
            || (state["kCGSessionLoginDoneKey"] as? Bool == false)
    }

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        func watch(_ name: Notification.Name, _ change: @escaping (Tracker) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    change(self)
                    self.sample()
                }
            }
            observers.append((center, token))
        }
        watch(NSWorkspace.didActivateApplicationNotification) { _ in }
        watch(NSWorkspace.willSleepNotification) { $0.systemSleeping = true }
        watch(NSWorkspace.didWakeNotification) { $0.systemSleeping = false; $0.clearOnResume() }
        watch(NSWorkspace.screensDidSleepNotification) { $0.screenSleeping = true }
        watch(NSWorkspace.screensDidWakeNotification) { $0.screenSleeping = false; $0.clearOnResume() }
        watch(NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        watch(NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false; $0.clearOnResume() }
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            let token = DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil,
                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.screenLocked = locked
                    if !locked { self.clearOnResume() }
                    self.sample()
                }
            }
            distributedObservers.append(token)
        }
    }

    private func clearOnResume() {
        engine.discardCoverage()
        feeds.removeAll()
        resetInteraction(at: Date())
    }
}
