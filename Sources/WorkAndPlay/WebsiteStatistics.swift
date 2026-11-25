import SwiftUI
import TimeCore
import TimeStore

struct WebsiteStatistics: View {
    let websites: [WebsiteTotal]
    let rules: [Rule]
    let showEntries: (WebsiteTotal) -> Void
    let classify: (WebsiteTotal, ActivityCategory) -> Void

    var body: some View {
        if websites.isEmpty {
            VStack(spacing: 6) {
                Text("这个周期没有网站记录").font(.callout.weight(.medium))
                Text("在已连接扩展的 Chrome 或 Edge 前台浏览普通网页后，这里会按域名汇总。")
                    .font(.caption)
            }
            .foregroundStyle(Color.workMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 25)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(websites.count) 个域名 · Chrome 与 Edge 合计")
                        .font(.system(size: 12, weight: .medium))
                    Text("有有效停留的网页连续在前台算一次访问。时长按空闲和排班规则计算。")
                    if !rules.isEmpty {
                        Text("网站规则用于新记录。工作和摸鱼时长来自所选周期的历史片段。")
                    }
                    if websites.contains(where: \.hasEarlierFragments) {
                        Text("早期片段已计入停留时长，访问次数从新版开始记录。")
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.workMuted)
                .padding(.bottom, 8)
                LazyVStack(spacing: 0) {
                    ForEach(websites) { website in
                        row(website)
                        if website.id != websites.last?.id { Divider().overlay(Color.workBorder.opacity(0.7)) }
                    }
                }
            }
            .padding(.top, 13)
        }
    }

    private func row(_ website: WebsiteTotal) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .foregroundStyle(Color.workAccent)
                .frame(width: 30, height: 30)
                .background(Color.workAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(website.id).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        .help(website.id)
                    let rule = Rule.classify(ActivityIdentity(appID: "", appName: website.id, host: website.id), using: rules)
                    if rule.ruleID != nil {
                        Text("后续\(rule.category.title)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.workAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.workAccent.opacity(0.1), in: Capsule())
                            .fixedSize()
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        categoryAmount(.regular, website.work, label: "工作")
                        categoryAmount(.entertainment, website.entertainment, label: "摸鱼")
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        categoryAmount(.regular, website.work, label: "工作")
                        categoryAmount(.entertainment, website.entertainment, label: "摸鱼")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            measure("前台访问", visitsText(website), width: 70)
            measure("有效停留", durationText(website.duration), width: 100)

            Button("查看片段") { showEntries(website) }
            Menu("设为") {
                Button("设为工作", systemImage: "briefcase") { classify(website, .work) }
                Button("设为摸鱼", systemImage: "play.circle") { classify(website, .entertainment) }
            }
            .fixedSize()
            .accessibilityLabel("设置 \(website.id) 的分类")
        }
        .controlSize(.small)
        .padding(.vertical, 11)
    }

    private func categoryAmount(_ bucket: Bucket, _ duration: TimeInterval, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(bucket.color).frame(width: 5, height: 5).accessibilityHidden(true)
            Text("\(label) \(durationText(duration))")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(bucket.color)
        .lineLimit(1)
    }

    private func measure(_ label: String, _ value: String, width: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(value).font(.system(size: 12, weight: .semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(Color.workMuted)
        }
        .frame(width: width, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private func visitsText(_ website: WebsiteTotal) -> String {
        if !website.hasEarlierFragments { return "\(website.visits) 次" }
        return website.visits == 0 ? "未记录" : "至少 \(website.visits) 次"
    }
}
