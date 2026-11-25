import SwiftUI
import TimeCore
import TimeStore

struct ClassificationAnalysis: View {
    let sources: [SourceBreakdown]
    let addRule: (SourceBreakdown) -> Void
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
                Text("\(sources.count) 个来源 · \(sources.filter(\.isMixed).count) 个同时有工作和摸鱼")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.workMuted)
                    .padding(.top, 13)
                Text("工作含普通工时与加班。普通时段里，未识别为工作的活动计入摸鱼。")
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
                if item.isMixed {
                    Text("混合用途")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.workMuted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.workSidebar, in: Capsule())
                }
                Spacer(minLength: 6)
                Button("查看片段") { showEntries(item) }
                Button("添加规则") { addRule(item) }
            }
            .controlSize(.small)

            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Bucket.displayCases) { bucket in
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
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Color.workMuted)
        }
        .padding(.vertical, 11)
    }

    private func amount(_ name: String, _ value: TimeInterval) -> some View {
        Text("\(name) \(durationText(value))")
    }
}
