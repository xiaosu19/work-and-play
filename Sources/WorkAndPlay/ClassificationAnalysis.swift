import SwiftUI
import TimeCore
import TimeStore

struct ClassificationAnalysis: View {
    enum Mode {
        case allSources(addRule: (SourceBreakdown) -> Void)
        case applications(rules: [Rule], classify: (SourceBreakdown, ActivityCategory) -> Void)
    }

    let sources: [SourceBreakdown]
    let mode: Mode
    let showEntries: (SourceBreakdown) -> Void

    var body: some View {
        if sources.isEmpty {
            Text("这个周期没有可分析的活动")
                .font(.callout)
                .foregroundStyle(Color.workMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 25)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("\(sources.count) 个\(sourceName) · \(sources.filter(\.isMixed).count) 个同时有工作和摸鱼")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.workMuted)
                    .padding(.top, 13)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Color.workMuted)
                    .padding(.top, 5)
                    .padding(.bottom, 7)

                ForEach(sources) { item in
                    row(item)
                    if item.id != sources.last?.id {
                        Divider().overlay(Color.workBorder.opacity(0.7))
                    }
                }
            }
        }
    }

    private var sourceName: String {
        if case .applications = mode { return "应用" }
        return "来源"
    }

    private var summary: String {
        if case .applications = mode {
            return "按 App 汇总前台片段，工作含普通工时与加班。应用规则用于之后的记录。"
        }
        return "工作含普通工时与加班。无法判断用途的浏览器片段会单列为网页未识别。"
    }

    private func row(_ item: SourceBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.id.host == nil ? "app.dashed" : "globe")
                    .foregroundStyle(Color.workAccent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.total.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if item.id.host != nil {
                        Text(item.total.appName).font(.caption).foregroundStyle(Color.workMuted)
                    }
                }
                if let badge = badge(for: item) {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.workMuted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.workSidebar, in: Capsule())
                }
                Spacer(minLength: 6)
                if case .applications = mode {
                    Text("\(durationText(item.total.duration)) · \(item.total.count) 条片段")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.workMuted)
                }
                Button("查看片段") { showEntries(item) }
                switch mode {
                case .allSources(let addRule):
                    if item.id.appID != Classification.deviceIdle.appID {
                        Button("添加规则") { addRule(item) }
                    }
                case .applications(_, let classify):
                    Menu("设为") {
                        Button("设为工作", systemImage: "briefcase") { classify(item, .work) }
                        Button("设为摸鱼", systemImage: "play.circle") { classify(item, .entertainment) }
                    }
                    .fixedSize()
                    .accessibilityLabel("设置 \(item.total.appName) 的分类")
                }
            }
            .controlSize(.small)

            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Bucket.reportCases) { bucket in
                        let duration = item.byBucket[bucket, default: 0]
                        Rectangle()
                            .fill(bucket.color)
                            .frame(width: geo.size.width * duration / item.total.duration)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
            .accessibilityHidden(true)

            HStack(spacing: 16) {
                amount("工作", item.work)
                amount("摸鱼", item.entertainment)
                if let missingWebsites = item.byBucket[.review], missingWebsites > 0 {
                    amount(Bucket.review.title, missingWebsites)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Color.workMuted)
        }
        .padding(.vertical, 11)
    }

    private func badge(for item: SourceBreakdown) -> String? {
        if case let .applications(rules, _) = mode, let appID = item.id.appID,
           let rule = rules.last(where: { $0.appID.caseInsensitiveCompare(appID) == .orderedSame }) {
            return "后续\(rule.category.title)"
        }
        return item.isMixed ? "混合用途" : nil
    }

    private func amount(_ name: String, _ value: TimeInterval) -> some View {
        Text("\(name) \(durationText(value))")
    }
}
