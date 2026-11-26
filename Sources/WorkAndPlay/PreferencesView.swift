import AppKit
import ChromeBridge
import SwiftUI
import TimeCore

struct PreferencesView: View {
    @ObservedObject var tracker: Tracker
    @State private var tab = "tracking"

    var body: some View {
        VStack(alignment: .leading) {
            TabView(selection: $tab) {
                TrackingSettings(tracker: tracker).tabItem { Label("计时", systemImage: "timer") }.tag("tracking")
                RuleSettings(tracker: tracker).tabItem { Label("分类规则", systemImage: "line.3.horizontal.decrease") }.tag("rules")
                ScheduleSettings(tracker: tracker).tabItem { Label("休息排班", systemImage: "calendar") }.tag("schedule")
            }
            if let error = tracker.errorMessage {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    .padding(.horizontal, 8)
            }
        }
        .padding(14)
    }
}

private struct TrackingSettings: View {
    @ObservedObject var tracker: Tracker
    @State private var idle = ""
    @State private var reading = ""
    @State private var video = false
    @State private var countIdle = false

    var body: some View {
        Form {
            Section("活动续计") {
                TextField("操作空闲上限（秒）", text: $idle).monospacedDigit()
                TextField("阅读续计上限（秒）", text: $reading).monospacedDigit()
                Toggle("普通时段的空闲计入摸鱼", isOn: $countIdle)
                Text("超过操作空闲上限后的时间记为设备空闲。锁屏和睡眠从系统状态切换时起计入，有效阅读和前台视频计时优先。")
                    .foregroundStyle(.secondary)
                Toggle("前台视频播放时持续计入摸鱼", isOn: $video)
                Text("Chrome 和 Edge 的已识别非工作视频可按播放状态续计。原生 App 按前台操作和空闲上限计时。")
                    .foregroundStyle(.secondary)
                Button("保存计时设置") { save() }
                    .disabled(![idle, reading].allSatisfy { (1...7200).contains(Int($0) ?? 0) })
                Text("秒数范围为 1–7200。").font(.caption).foregroundStyle(.secondary)
            }
            Section("识别精度") {
                LabeledContent("当前信号", value: tracker.precision)
                LabeledContent("辅助功能", value: tracker.accessibility ? "已启用" : "未启用")
                if !tracker.accessibility {
                    Button("请求窗口识别权限") { tracker.openAccessibilityPrompt() }
                }
                Text("已连接表示扩展能和工时簿通信。打开有访问权限的普通网页时，当前信号会显示「页面级」。安装或重新加载扩展后，已打开的网页可能需要刷新。")
                    .foregroundStyle(.secondary)
                ForEach(BrowserSource.allCases, id: \.self) { browser in
                    HStack {
                        Text("\(browser.label) 网页信号")
                        Spacer()
                        Text(tracker.browserConnections.contains(browser) ? "扩展已连接" : "扩展未连接")
                            .foregroundStyle(.secondary)
                        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.rawValue),
                           let extensionsPage = URL(string: browser == .edge ? "edge://extensions" : "chrome://extensions") {
                            Button("打开\(browser.label)扩展页") {
                                NSWorkspace.shared.open([extensionsPage], withApplicationAt: app,
                                                        configuration: NSWorkspace.OpenConfiguration())
                            }
                        }
                    }
                }
                if let folder = Bundle.main.resourceURL?.appendingPathComponent("chrome-extension") {
                    Button("显示浏览器扩展文件夹", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    Text("在 Chrome 或 Edge 的扩展页选择「加载已解压的扩展程序」，然后选这个文件夹。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            idle = String(tracker.preferences.idleSeconds)
            reading = String(tracker.preferences.readingSeconds)
            video = tracker.preferences.countVideo
            countIdle = tracker.preferences.countIdleAsEntertainment
        }
    }

    private func save() {
        guard let idleSeconds = Int(idle), let readingSeconds = Int(reading) else { return }
        var next = tracker.preferences
        next.idleSeconds = idleSeconds
        next.readingSeconds = readingSeconds
        next.countVideo = video
        next.countIdleAsEntertainment = countIdle
        _ = tracker.update(next)
    }
}

private struct RuleSettings: View {
    @ObservedObject var tracker: Tracker
    @State private var editing: Rule?
    @State private var removing: Rule?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("分类规则").font(.title2.bold())
                    Text("有路径、窗口或项目条件的规则优先。同等具体时采用列表中靠上的规则。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("新增规则", systemImage: "plus") { editing = Rule() }
            }
            List(tracker.preferences.rules.reversed()) { rule in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.scope).lineLimit(1)
                        Text("\(rule.category.title) · \(rule.kind.title)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("编辑") { editing = rule }
                    Button { removing = rule } label: { Image(systemName: "trash") }
                        .help("删除分类规则")
                }
                .padding(.vertical, 4)
            }
            .listStyle(.bordered)
        }
        .padding(14)
        .sheet(item: $editing) { rule in
            RuleEditor(tracker: tracker, rule: rule)
        }
        .alert("删除这条规则？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("取消", role: .cancel) { removing = nil }
            Button("删除", role: .destructive) {
                if let removing {
                    var next = tracker.preferences
                    next.rules.removeAll { $0.id == removing.id }
                    _ = tracker.update(next)
                }
                removing = nil
            }
        } message: {
            Text("删除只影响后续分类。")
        }
    }
}

enum RuleEditorScope {
    case custom, website, application

    var title: String {
        switch self {
        case .custom: "分类规则"
        case .website: "网站规则"
        case .application: "应用规则"
        }
    }
}

struct RuleEditor: View {
    @ObservedObject var tracker: Tracker
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    var guidance: String?
    var scope = RuleEditorScope.custom

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(scope.title).font(.title2.bold())
            if let guidance { Text(guidance).font(.callout).foregroundStyle(.secondary) }
            RuleFields(rule: $rule, scope: scope)
            if let error = tracker.errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存规则") {
                    var next = tracker.preferences
                    if let index = next.rules.firstIndex(where: { $0.id == rule.id }) {
                        next.rules[index] = rule
                    } else {
                        next.rules.append(rule)
                    }
                    if tracker.update(next) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!rule.valid)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

struct RuleFields: View {
    @Binding var rule: Rule
    var showCategory = true
    var scope = RuleEditorScope.custom

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if scope == .custom {
                field("App 标识", text: $rule.appID, example: "可选，例如 com.apple.Terminal")
                field("窗口标题包含", text: $rule.windowContains, example: "可选")
            }
            if scope != .application {
                field("域名", text: $rule.host, example: "docs.example.com 或 *.example.com")
            } else {
                LabeledContent("App 标识", value: rule.appID)
            }
            if scope == .custom {
                field("路径前缀", text: $rule.pathPrefix, example: "/work")
                field("项目标识", text: $rule.project, example: "窗口标题或路径中的关键词")
            }
            if showCategory {
                Picker("类别", selection: Binding(
                    get: { rule.category == .work ? .work : .entertainment },
                    set: { rule.category = $0 }
                )) {
                    ForEach(ActivityCategory.displayCases) { Text($0.title).tag($0) }
                }
            }
            Picker("计时方式", selection: $rule.kind) {
                ForEach(ActivityKind.allCases) { Text($0.title).tag($0) }
            }
            if scope != .application {
                Text("*.example.com 或 *example.com 覆盖主域名和子域名。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if scope == .custom {
                Text("至少填一项，所填条件需同时匹配。App 标识使用 Bundle ID。路径按目录匹配，并需填写域名。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, example: String) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(example))
                .labelsHidden()
        }
    }
}
