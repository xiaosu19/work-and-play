import AppKit
import ChromeBridge
import SwiftUI
import TimeCore
import TimeStore

struct ReportView: View {
    @ObservedObject var tracker: Tracker
    let openBrowserSetup: () -> Void
    @State private var period: ReportPeriod = .day
    @State private var date = Date()
    @State private var filter: Bucket?
    @State private var mode: DetailMode = .sources
    @State private var source: SourceTotal?
    @State private var page = 0
    @State private var totals: [ReportTotal] = []
    @State private var timeline: [ReportEntry] = []
    @State private var entries: [ReportEntry] = []
    @State private var sources: [SourceTotal] = []
    @State private var breakdown: [SourceBreakdown] = []
    @State private var websites: [WebsiteTotal] = []
    @State private var ruleSource: SourceBreakdown?
    @State private var websiteRule: Rule?
    @State private var editing: ReportEntry?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pageSize = 40
    private let headlineBuckets = Bucket.displayCases
    private let detailsID = "report-details"
    private var days: ClosedRange<String> { period.dayRange(for: date) }
    private var selection: ReportSelection { ReportSelection(period: period, days: days) }
    private var detailCount: Int {
        source?.count ?? totals.reduce(0) { $0 + (filter == nil || filter == $1.bucket ? $1.count : 0) }
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    header
                    HStack(spacing: 12) {
                        ForEach(headlineBuckets) { bucket in
                            MetricTile(bucket: bucket, duration: duration(for: bucket),
                                       count: count(for: bucket), selected: filter == bucket) {
                                select(bucket)
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                                    scroll.scrollTo(detailsID, anchor: .top)
                                }
                            }
                        }
                    }

                    ActivityChart(period: period, anchor: date, totals: totals, entries: timeline)
                    if let error = tracker.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                    detailCard(scroll).id(detailsID)
                }
                .padding(.horizontal, 24)
                .padding(.top, 19)
                .padding(.bottom, 24)
                .frame(maxWidth: 1340)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
        }
        .background(Color.workCanvas)
        .onAppear { tracker.refreshReport() }
        .onChange(of: selection, initial: true) { _, _ in
            page = 0
            source = nil
            load()
        }
        .onChange(of: tracker.revision) { _, _ in load() }
        .sheet(item: $editing) { CorrectionView(entry: $0, tracker: tracker) }
        .sheet(item: $ruleSource) { item in
            RuleEditor(tracker: tracker, rule: Rule(appID: item.id.appID ?? "", host: item.id.host ?? ""),
                       guidance: item.id.host == nil
                        ? "此规则只影响未来。可用窗口标题或项目区分同一个 App 的不同用法。"
                        : "此规则只影响未来。可用路径前缀区分同一网站的工作和摸鱼活动。")
        }
        .sheet(item: $websiteRule) { rule in
            RuleEditor(tracker: tracker, rule: rule,
                       guidance: "保存后适用于 Chrome 和 Edge 的新记录。更具体的规则优先。", websiteOnly: true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center) {
                Text("时间总览")
                    .font(.system(size: 33, weight: .semibold))
                    .heading()
                Spacer()
                Picker("统计周期", selection: $period) {
                    ForEach(ReportPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                .frame(width: 236)
            }

            HStack(spacing: 8) {
                Text(period.title(for: date))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.workMuted)
                    .contentTransition(.numericText())
                Spacer()
                if period != .all {
                    Button { date = period.moving(date, by: -1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("上一个周期")
                    DatePicker("选择统计日期", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                    Button { date = period.moving(date, by: 1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .accessibilityLabel("下一个周期")
                    Button("今天") { date = .now; tracker.refreshReport() }
                }
            }
            .controlSize(.small)
        }
    }

    private func detailCard(_ scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(mode.heading)
                    .font(.system(size: 19, weight: .semibold))
                    .heading()
                Spacer()
                Picker("明细方式", selection: Binding(get: { mode }, set: setMode)) {
                    ForEach(DetailMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
            }
            .padding(.bottom, 13)

            if mode == .sources || mode == .entries {
                HStack(spacing: 5) {
                    filterChip(nil)
                    ForEach(Bucket.displayCases) { filterChip($0) }
                    Spacer(minLength: 6)
                    if mode == .entries && pageCount > 1 {
                        Button { page -= 1; loadDetails() } label: { Image(systemName: "chevron.left") }
                            .disabled(page == 0)
                            .accessibilityLabel("上一页片段")
                        Text("\(page + 1)/\(pageCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.workMuted)
                        Button { page += 1; loadDetails() } label: { Image(systemName: "chevron.right") }
                            .disabled(page + 1 >= pageCount)
                            .accessibilityLabel("下一页片段")
                    }
                    Text(detailCaption)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.workMuted)
                }
                .controlSize(.small)
                .padding(.bottom, 11)
            }

            if let source {
                HStack(spacing: 8) {
                    if let browser = browserWithoutPage(source) {
                        Label("\(browser.label) · 仅记录到浏览器", systemImage: "app.dashed")
                    } else {
                        Label(source.label, systemImage: source.id.host == nil ? "app.dashed" : "globe")
                    }
                    Button("清除此来源", systemImage: "xmark.circle.fill") {
                        self.source = nil
                        page = 0
                        loadDetails()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    if let browser = browserWithoutPage(source), !tracker.browserConnections.contains(browser) {
                        Button("设置网页识别", action: openBrowserSetup).controlSize(.small)
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.workAccent)
                .padding(.bottom, 11)
            }
            Divider().overlay(Color.workBorder)

            switch mode {
            case .entries: fragmentRows(scroll)
            case .sources: sourceRows
            case .websites:
                WebsiteStatistics(websites: websites, rules: tracker.preferences.rules.filter(\.isWebsiteOnly), showEntries: { website in
                    filter = nil
                    source = website.source
                    setMode(.entries, keepSource: true)
                }, classify: { website, category in
                    websiteRule = tracker.suggestedRule(forWebsite: website.id, category: category)
                })
            case .analysis:
                ClassificationAnalysis(sources: breakdown, addRule: { ruleSource = $0 }, showEntries: { item in
                    filter = nil
                    source = item.total
                    setMode(.entries, keepSource: true)
                })
            }
        }
        .padding(17)
        .workCard()
    }

    private var detailCaption: String {
        mode == .sources ? "\(sources.count) 个来源" : "\(detailCount) 条片段"
    }

    private func filterChip(_ bucket: Bucket?) -> some View {
        let selected = filter == bucket
        let title = bucket?.title ?? "全部片段"
        return Button {
            select(bucket, showSources: false)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? Color.workAccent : Color.workMuted)
                .background(selected ? Color.workAccent.opacity(0.13) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func fragmentRows(_ scroll: ScrollViewProxy) -> some View {
        if entries.isEmpty {
            emptyState(filter.map { "这个周期没有\($0.title)片段" } ?? "这个周期没有活动记录")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    FragmentRow(entry: entry, showDate: period != .day) { editing = entry }
                    if entry.id != entries.last?.id { Divider().overlay(Color.workBorder.opacity(0.7)) }
                }
            }
            if detailCount > pageSize {
                HStack {
                    Text("第 \(page + 1) 页，共 \(pageCount) 页")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.workMuted)
                    Spacer()
                    Button("上一页") { movePage(-1, scroll: scroll) }.disabled(page == 0)
                    Button("下一页") { movePage(1, scroll: scroll) }.disabled(page + 1 >= pageCount)
                }
                .padding(.top, 12)
                .controlSize(.small)
            }
        }
    }

    private func movePage(_ offset: Int, scroll: ScrollViewProxy) {
        page += offset
        loadDetails()
        scroll.scrollTo(detailsID, anchor: .top)
    }

    private var pageCount: Int { max(1, (detailCount + pageSize - 1) / pageSize) }

    @ViewBuilder
    private var sourceRows: some View {
        if sources.isEmpty {
            emptyState("这个周期没有匹配的应用或网站")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(sources) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.id.host == nil ? "app.dashed" : "globe")
                            .foregroundStyle(Color.workAccent)
                            .frame(width: 30, height: 30)
                            .background(Color.workAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            let countLabel = "\(item.count) 条片段"
                            Text(sourceSubtitle(item, count: countLabel))
                                .font(.caption)
                                .foregroundStyle(Color.workMuted)
                        }
                        Spacer()
                        Text(durationText(item.duration))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        if let browser = browserWithoutPage(item), !tracker.browserConnections.contains(browser) {
                            Button("设置网页识别", action: openBrowserSetup).controlSize(.small)
                        }
                        Button("查看片段") {
                            source = item
                            setMode(.entries, keepSource: true)
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 10)
                    if item.id != sources.last?.id { Divider().overlay(Color.workBorder.opacity(0.7)) }
                }
            }
        }
    }

    private func browserWithoutPage(_ item: SourceTotal) -> BrowserSource? {
        item.id.host == nil ? item.id.appID.flatMap(BrowserSource.init(rawValue:)) : nil
    }

    private func sourceSubtitle(_ item: SourceTotal, count: String) -> String {
        if item.id.host != nil { return "\(item.appName) · \(count)" }
        if browserWithoutPage(item) != nil { return "仅记录到浏览器 · \(count)" }
        return count
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "clock")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.workAccent)
                .frame(width: 38, height: 38)
                .background(Color.workAccent.opacity(0.11), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .foregroundStyle(Color.workMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private func select(_ bucket: Bucket?, showSources: Bool = true) {
        filter = bucket
        page = 0
        source = nil
        if showSources { mode = .sources }
        loadDetails()
    }

    private func setMode(_ next: DetailMode) { setMode(next, keepSource: false) }

    private func setMode(_ next: DetailMode, keepSource: Bool) {
        mode = next
        page = 0
        if !keepSource { source = nil }
        loadDetails()
    }

    private func load() {
        totals = tracker.totals(dayRange: days)
        timeline = period == .day ? tracker.report(dayRange: days).entries : []
        if let current = source {
            switch current.id {
            case .application:
                source = tracker.sourceTotals(dayRange: days, bucket: filter).first { $0.id == current.id }
            case .website(let host):
                source = tracker.websiteTotals(dayRange: days).first { $0.id == host }?.source
            }
        }
        page = min(page, pageCount - 1)
        loadDetails()
    }

    private func loadDetails() {
        switch mode {
        case .entries:
            entries = tracker.report(dayRange: days, bucket: filter, source: source?.id,
                                     limit: pageSize, offset: page * pageSize, newestFirst: period != .day).entries
        case .sources:
            sources = tracker.sourceTotals(dayRange: days, bucket: filter)
        case .websites:
            websites = tracker.websiteTotals(dayRange: days)
        case .analysis:
            breakdown = tracker.sourceBreakdown(dayRange: days)
        }
    }

    private func count(for bucket: Bucket) -> Int {
        totals.lazy.filter { $0.bucket == bucket }.reduce(0) { $0 + $1.count }
    }

    private func duration(for bucket: Bucket) -> TimeInterval {
        totals.lazy.filter { $0.bucket == bucket }.reduce(0) { $0 + $1.duration }
    }
}

private struct ReportSelection: Equatable {
    let period: ReportPeriod
    let days: ClosedRange<String>
}

private enum DetailMode: String, CaseIterable, Identifiable {
    case entries = "时间片段"
    case sources = "应用与网站"
    case websites = "网站统计"
    case analysis = "分类分析"
    var id: Self { self }

    var heading: String {
        switch self {
        case .entries, .sources: "活动明细"
        case .websites, .analysis: rawValue
        }
    }
}

private struct MetricTile: View {
    let bucket: Bucket
    let duration: TimeInterval
    let count: Int
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            GeometryReader { geometry in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(bucket.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(durationText(duration))
                            .font(.system(size: 27, weight: .semibold, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.63)
                        Text("\(count) 条片段")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.workMuted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    MetricSticker(bucket: bucket)
                        .frame(width: min(106, geometry.size.width * 0.37), height: 106)
                }
                .padding(.leading, 15)
                .padding(.trailing, 19)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.down.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.workMuted)
                        .accessibilityHidden(true)
                        .padding(14)
                }
            }
            .frame(height: 136)
            .background(bucket.color.opacity(selected ? 0.15 : 0.055), in: RoundedRectangle(cornerRadius: 19))
            .background(Color.workSurface, in: RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(selected ? bucket.color.opacity(0.65) : Color.workBorder)
                .allowsHitTesting(false))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(bucket.title)
        .accessibilityValue("\(durationText(duration))，\(count) 条片段")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help("查看\(bucket.title)片段")
    }

}

private struct MetricSticker: View {
    let bucket: Bucket

    private static let images: [Bucket: NSImage] = [.regular: "working", .overtime: "overtime", .entertainment: "moyu"]
        .compactMapValues { name in
            Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "MetricStickers")
                .flatMap(NSImage.init(contentsOf:))
        }

    var body: some View {
        Group {
            if let image = Self.images[bucket] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: bucket.symbol)
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(bucket.color)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct FragmentRow: View {
    let entry: ReportEntry
    let showDate: Bool
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Circle().fill(entry.bucket.color).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(Color.workMuted)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(clock(entry.start)) – \(clock(entry.end))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                Text(durationText(entry.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.workMuted)
            }
            Button("修正", action: edit)
                .controlSize(.small)
        }
        .padding(.vertical, 10)
    }

    private var metadata: String {
        let date = showDate ? entry.day : nil
        let zone = entry.timeZoneID == TimeZone.current.identifier ? nil : entry.timeZoneID
        return [date, entry.bucket.title, entry.kind.title, entry.host == nil ? nil : entry.appName,
                classificationDetail, entry.restReason, zone]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var classificationDetail: String {
        if entry.corrected { return "已修正" }
        if entry.basis == .none, entry.host == nil, BrowserSource(rawValue: entry.appID) != nil {
            return "当时未取得网页信息"
        }
        return entry.basis.title
    }

    private func clock(_ date: Date) -> String {
        let zone = TimeZone(identifier: entry.timeZoneID) ?? .current
        let style = Date.FormatStyle(locale: Locale(identifier: "zh_CN"), timeZone: zone)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        return date.formatted(style)
    }
}

private extension ClassificationBasis {
    var title: String {
        switch self {
        case .app: "App 规则"
        case .window: "窗口规则"
        case .domain: "域名规则"
        case .path: "路径规则"
        case .project: "项目规则"
        case .automaticApp: "自动识别 · App"
        case .applicationCategory: "自动识别 · macOS App 类别"
        case .automaticDomain: "自动识别 · 网站"
        case .automaticPath: "自动识别 · 网页用途"
        case .automaticWindow: "自动识别 · 窗口"
        case .none: "未识别到工作线索"
        }
    }
}

private struct CorrectionView: View {
    let entry: ReportEntry
    @ObservedObject var tracker: Tracker
    @Environment(\.dismiss) private var dismiss
    @State private var rule: Rule
    @State private var saveRule = false

    init(entry: ReportEntry, tracker: Tracker) {
        self.entry = entry
        self.tracker = tracker
        _rule = State(initialValue: tracker.suggestedRule(for: entry))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("修正片段").font(.title2.bold())
            Text("\(entry.label) · \(durationText(entry.duration))").foregroundStyle(.secondary)
            Picker("类别", selection: Binding(
                get: { rule.category == .work ? .work : .entertainment },
                set: { rule.category = $0 }
            )) {
                ForEach(ActivityCategory.displayCases) { Text($0.title).tag($0) }
            }
            if entry.restReason != nil && rule.category != .work {
                Text("休息时段只保留工作。保存后这条片段会被删除。")
                    .foregroundStyle(.secondary)
            }
            Toggle("同时保存为未来规则", isOn: $saveRule)
            if saveRule { RuleFields(rule: $rule, showCategory: false) }
            if let error = tracker.errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存修正") {
                    if tracker.correct(entry, to: rule.category, futureRule: saveRule ? rule : nil) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saveRule && !rule.valid)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}
