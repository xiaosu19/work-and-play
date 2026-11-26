import SwiftUI
import TimeCore
import TimeStore

struct ActivityChart: View {
    let period: ReportPeriod
    let anchor: Date
    let totals: [ReportTotal]
    let report: DailyReport
    let schedule: Schedule
    let showMissingWebsites: () -> Void

    private static let gapColor = Color.workMuted.opacity(0.30)

    var body: some View {
        let gaps = period == .day ? report.unrecordedOrdinaryIntervals(schedule: schedule) : []
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(period == .day ? "当天时间分布" : "时长趋势")
                    .font(.system(size: 19, weight: .semibold))
                    .heading()
                Spacer()
                let tracked = totals.reduce(0) { $0 + $1.duration }
                Text("记录合计 \(durationText(tracked))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.workMuted)
                    .help("合计包括普通工时、加班、摸鱼和网页未识别时长。")
            }

            if period == .day {
                DailyTimeline(anchor: anchor, entries: report.entries, gaps: gaps, gapColor: Self.gapColor)
            } else {
                TrendChart(columns: period.chartColumns(anchor: anchor, totals: totals))
            }

            HStack(spacing: 15) {
                ForEach(Bucket.displayCases) { bucket in
                    legend(bucket, title: bucket.title)
                }
                let missingWebsites = totals.lazy.filter { $0.bucket == .review }.reduce(0) { $0 + $1.duration }
                if missingWebsites > 0 {
                    Button(action: showMissingWebsites) {
                        legend(.review, title: "网页未识别 \(durationText(missingWebsites))")
                    }
                    .buttonStyle(.plain)
                    .help("查看只记录到浏览器的片段")
                }
                Spacer(minLength: 4)
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.workMuted)

            if let entry = report.entries.first, !gaps.isEmpty {
                UnrecordedDetails(gaps: gaps, timeZone: TimeZone(identifier: entry.timeZoneID) ?? .current,
                                  swatch: Self.gapColor)
                    .id(entry.day)
            }
        }
        .padding(17)
        .workCard()
    }

    private func legend(_ bucket: Bucket, title: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(bucket.color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(title)
        }
    }
}

private struct UnrecordedDetails: View {
    let gaps: [DateInterval]
    let timeZone: TimeZone
    let swatch: Color

    @State private var expanded = false
    @State private var page = 0

    private let pageSize = 8
    private var pageCount: Int { max(1, (gaps.count + pageSize - 1) / pageSize) }

    var body: some View {
        let total = gaps.reduce(0) { $0 + $1.duration }
        DisclosureGroup(isExpanded: $expanded) {
            pageContent
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(swatch)
                    .frame(width: 10, height: 7)
                    .accessibilityHidden(true)
                Text("未计入 \(durationText(total))")
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.workMuted)
        }
        .onChange(of: expanded) { _, isExpanded in
            if !isExpanded { page = 0 }
        }
        .onChange(of: pageCount) { _, pages in
            page = min(page, pages - 1)
        }
    }

    private var pageContent: some View {
        let visiblePage = min(page, pageCount - 1)
        let sorted = gaps.sorted {
            if $0.duration == $1.duration { return $0.start < $1.start }
            return $0.duration > $1.duration
        }
        let visibleGaps = sorted.dropFirst(visiblePage * pageSize).prefix(pageSize)
        let clock = Date.FormatStyle(date: .omitted, time: .standard, locale: Locale(identifier: "zh_CN"), timeZone: timeZone)

        return VStack(alignment: .leading, spacing: 7) {
            Text("按当前排班，只列当天首尾记录之间的普通时段。开启清醒空闲统计后，无操作达到空闲上限才开始计入。")
                .fixedSize(horizontal: false, vertical: true)
            if pageCount > 1 {
                HStack(spacing: 8) {
                    Text("\(gaps.count) 段空档")
                    Spacer()
                    Button { page = visiblePage - 1 } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(visiblePage == 0)
                    .accessibilityLabel("上一页空档")
                    Text("第 \(visiblePage + 1) 页，共 \(pageCount) 页")
                    Button { page = visiblePage + 1 } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(visiblePage + 1 == pageCount)
                    .accessibilityLabel("下一页空档")
                }
                .controlSize(.small)
                .monospacedDigit()
            }
            ForEach(visibleGaps, id: \.start) { gap in
                HStack {
                    Text("\(gap.start.formatted(clock)) – \(gap.end.formatted(clock))")
                    Spacer()
                    Text(durationText(gap.duration))
                }
                .monospacedDigit()
                .accessibilityElement(children: .combine)
            }
        }
        .font(.caption)
        .foregroundStyle(Color.workMuted)
        .padding(.top, 6)
    }
}

private struct DailyTimeline: View {
    let anchor: Date
    let entries: [ReportEntry]
    let gaps: [DateInterval]
    let gapColor: Color

    var body: some View {
        let zones = Set(entries.map(\.timeZoneID))
        if zones.count > 1 {
            Text("当天涉及多个时区，各片段的当地时间可在明细查看。")
                .font(.callout)
                .foregroundStyle(Color.workMuted)
                .padding(.vertical, 8)
        } else {
            let calendar = calendar(in: zones.first)
            if let day = calendar.dateInterval(of: .day, for: entries.first?.start ?? anchor) {
                track(day, calendar: calendar)
                    .accessibilityLabel("当天当地时间轴")
                    .accessibilityHint("完整记录可以在活动明细查看。")
            }
        }
    }

    private func track(_ day: DateInterval, calendar: Calendar) -> some View {
        let markers = [6, 12, 18].compactMap { hour -> (String, TimeInterval)? in
            guard let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day.start) else { return nil }
            return (String(format: "%02d:00", hour), date.timeIntervalSince(day.start) / day.duration)
        }

        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let bar = CGRect(x: 0, y: 0, width: size.width, height: 23)
                    let outline = Path(roundedRect: bar, cornerRadius: 7)
                    context.fill(outline, with: .color(.workSidebar))
                    var fragments = context
                    fragments.clip(to: outline)
                    for gap in gaps {
                        let x = size.width * gap.start.timeIntervalSince(day.start) / day.duration
                        let width = size.width * gap.duration / day.duration
                        fragments.fill(Path(CGRect(x: x, y: 0, width: width, height: bar.height)), with: .color(gapColor))
                    }
                    for entry in entries {
                        let start = max(day.start, entry.start)
                        let end = min(day.end, entry.end)
                        if start < end {
                            let x = size.width * start.timeIntervalSince(day.start) / day.duration
                            let width = size.width * end.timeIntervalSince(start) / day.duration
                            // A visible hairline marks short entries on a full-day axis.
                            let rect = CGRect(x: x, y: 0, width: max(width, 1), height: bar.height)
                            fragments.fill(Path(rect), with: .color(entry.bucket.color))
                        }
                    }
                    for (_, offset) in markers {
                        let x = size.width * offset
                        let tick = Path { path in
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: 26))
                        }
                        context.stroke(tick, with: .color(.workMuted.opacity(0.36)), lineWidth: 1)
                    }
                }
                .accessibilityHidden(true)

                HStack {
                    axisLabel("00:00")
                    Spacer()
                    axisLabel("次日 00:00")
                }
                .padding(.top, 29)
                .accessibilityHidden(true)

                ForEach(markers, id: \.0) { title, offset in
                    axisLabel(title)
                        .position(x: geo.size.width * offset, y: 35)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: 43)
        .accessibilityElement(children: .ignore)
    }

    private func axisLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 10).monospacedDigit()).foregroundStyle(Color.workMuted)
    }

    private func calendar(in id: String?) -> Calendar {
        var calendar = ReportPeriod.calendar
        if let zone = id.flatMap(TimeZone.init(identifier:)) { calendar.timeZone = zone }
        return calendar
    }
}

private struct TrendChart: View {
    let columns: [ChartColumn]
    private let plotHeight: CGFloat = 104

    var body: some View {
        if columns.isEmpty {
            Text("开始记录后，这里会显示各年的时长。")
                .font(.callout)
                .foregroundStyle(Color.workMuted)
                .frame(maxWidth: .infinity, minHeight: 98)
        } else {
            let peak = columns.map(\.total).max() ?? 0
            let ceiling = chartCeiling(peak)
            HStack(alignment: .top, spacing: 9) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(axisDuration(ceiling))
                    Spacer(minLength: 0)
                    Text(axisDuration(ceiling / 2))
                    Spacer(minLength: 0)
                    Text("0")
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color.workMuted)
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: plotHeight + 9)
                .accessibilityHidden(true)

                HStack(alignment: .top, spacing: columns.count > 16 ? 3 : 8) {
                    ForEach(columns) { column in chartBar(column, ceiling: ceiling) }
                }
                .background(alignment: .top) {
                    VStack(spacing: 0) {
                        line
                        Spacer(minLength: 0)
                        line
                        Spacer(minLength: 0)
                        line
                    }
                    .frame(height: plotHeight)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
                }
                .layoutPriority(1)
            }
        }
    }

    private var line: some View { Rectangle().fill(Color.workBorder).frame(height: 1) }

    private func chartBar(_ column: ChartColumn, ceiling: TimeInterval) -> some View {
        VStack(spacing: 5) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    ForEach(Bucket.reportCases.reversed()) { bucket in
                        if let amount = column.amounts[bucket], amount > 0 {
                            Rectangle().fill(bucket.color)
                                .frame(height: max(1, plotHeight * amount / ceiling))
                        }
                    }
                }
                .frame(maxWidth: 34)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(.horizontal, 1)
            }
            .frame(height: plotHeight)
            Text(column.title.isEmpty ? " " : column.title)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color.workMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(column.id)
        .accessibilityValue(Bucket.reportCases.compactMap {
            guard let amount = column.amounts[$0], amount > 0 else { return nil }
            return "\($0.title) \(durationText(amount))"
        }.joined(separator: "，"))
        .help("\(column.id) · \(durationText(column.total))")
    }

    private func chartCeiling(_ peak: TimeInterval) -> TimeInterval {
        let unit: Double = peak > 7200 ? 3600 : peak > 600 ? 600 : 60
        return max(unit * 2, (peak / (unit * 2)).rounded(.up) * unit * 2)
    }

    private func axisDuration(_ value: TimeInterval) -> String {
        value.truncatingRemainder(dividingBy: 3600) == 0 ? "\(Int(value / 3600)) 小时" : "\(Int(value / 60)) 分"
    }
}
