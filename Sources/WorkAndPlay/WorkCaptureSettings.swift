import AppKit
import CoreGraphics
import SwiftUI
import TimeCore

struct WorkCaptureSettings: View {
    @ObservedObject var tracker: Tracker
    @State private var editing: WorkCaptureRule?
    @State private var removing: WorkCaptureRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("操作描述").font(.title2.bold())
                    Text("为指定工作来源单独开启。报告使用项目别名和操作摘要。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加来源", systemImage: "plus") { editing = WorkCaptureRule() }
            }
            if tracker.preferences.workCaptureRules.isEmpty {
                ContentUnavailableView("未授权操作描述", systemImage: "text.badge.checkmark",
                                       description: Text("添加工作网站、应用窗口或客户会话。"))
            } else {
                List(tracker.preferences.workCaptureRules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.project).font(.headline)
                            Text(rule.label + " · " + rule.target).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("编辑") { editing = rule }
                        Button("撤销授权", systemImage: "minus.circle") { removing = rule }
                            .labelStyle(.iconOnly).help("撤销此来源的操作授权")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(14)
        .sheet(item: $editing) { WorkCaptureEditor(tracker: tracker, rule: $0) }
        .alert("撤销此来源的采集授权？",
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("取消", role: .cancel) { removing = nil }
            Button("撤销授权", role: .destructive) {
                guard let removing else { return }
                var preferences = tracker.preferences
                preferences.workCaptureRules.removeAll { $0.id == removing.id }
                _ = tracker.update(preferences)
                self.removing = nil
            }
        }
    }
}

private struct WorkCaptureEditor: View {
    @ObservedObject var tracker: Tracker
    @Environment(\.dismiss) private var dismiss
    @State var rule: WorkCaptureRule
    @State private var alsoSetWork = false
    @State private var screenAccess = false

    private var normalized: WorkCaptureRule {
        var copy = rule
        copy.target = rule.target.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.detail = rule.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.project = rule.project.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.keyword = rule.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("授权操作描述").font(.title2.bold())
            Form {
                Picker("来源", selection: $rule.scope) {
                    Text("工作网站").tag(WorkCaptureScope.website)
                    Text("原生应用").tag(WorkCaptureScope.application)
                    Text("客户会话").tag(WorkCaptureScope.conversation)
                }
                .onChange(of: rule.scope) { _, scope in
                    rule.target = scope == .conversation ? "com.tencent.xinWeChat" : ""
                    rule.detail = ""
                    rule.keyword = ""
                    rule.windowOCR = false
                }

                switch rule.scope {
                case .website:
                    TextField("域名", text: $rule.target, prompt: Text("docs.example.com"))
                    TextField("路径前缀（可选）", text: $rule.detail, prompt: Text("/work"))
                    TextField("页面章节关键词（可选）", text: $rule.keyword, prompt: Text("部署说明"))
                    Text("仅匹配此域名和路径。开启关键词后，扩展可核对可见章节标题。")
                        .foregroundStyle(.secondary)
                case .application:
                    HStack {
                        TextField("App 标识", text: $rule.target, prompt: Text("com.apple.TextEdit"))
                        Button("选择 App…", action: chooseApp)
                    }
                    TextField("完整窗口标题（可选）", text: $rule.detail)
                    LabeledContent("窗口识别", value: tracker.accessibility ? "已启用" : "未启用")
                    if !tracker.accessibility {
                        Button("请求辅助功能权限") { tracker.openAccessibilityPrompt() }
                    }
                    Toggle("对此窗口启用本机 OCR", isOn: $rule.windowOCR)
                    if rule.windowOCR {
                        TextField("窗口关键词", text: $rule.keyword)
                        Text("需要完整窗口标题和关键词。识别在本机完成，报告只记是否匹配。")
                            .foregroundStyle(.secondary)
                        LabeledContent("屏幕录制权限", value: screenAccess ? "已启用" : "未启用")
                        if !screenAccess {
                            Button("请求屏幕录制权限") { screenAccess = CGRequestScreenCaptureAccess() }
                        }
                    }
                case .conversation:
                    Picker("聊天 App", selection: $rule.target) {
                        Text("微信").tag("com.tencent.xinWeChat")
                        Text("企业微信").tag("com.tencent.WeWorkMac")
                    }
                    TextField("完整会话窗口标题", text: $rule.detail)
                    Text("仅使用可读取并精确匹配的会话窗口标题。互动会记成会话操作，可手动补记发送结果。")
                        .foregroundStyle(.secondary)
                    if !tracker.accessibility {
                        Button("请求辅助功能权限") { tracker.openAccessibilityPrompt() }
                    }
                }
                TextField("报告中的项目或客户别名", text: $rule.project, prompt: Text("例如 客户 A 交付"))
                Toggle("同时添加匹配的工作分类规则", isOn: $alsoSetWork)
                Text("采集范围与工作分类同时匹配时，才会生成操作记录。")
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .frame(minHeight: 298)
            if let error = tracker.errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存授权", action: save).keyboardShortcut(.defaultAction).disabled(!normalized.valid)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { if rule.windowOCR { screenAccess = CGPreflightScreenCaptureAccess() } }
        .onChange(of: rule.windowOCR) { _, enabled in
            if enabled { screenAccess = CGPreflightScreenCaptureAccess() }
        }
    }

    private func chooseApp() {
        let dialog = NSOpenPanel()
        dialog.allowedContentTypes = [.applicationBundle]
        dialog.directoryURL = URL(fileURLWithPath: "/Applications")
        dialog.canChooseDirectories = false
        if dialog.runModal() == .OK, let url = dialog.url, let id = Bundle(url: url)?.bundleIdentifier { rule.target = id }
    }

    private func save() {
        let rule = normalized
        var preferences = tracker.preferences
        if let index = preferences.workCaptureRules.firstIndex(where: { $0.id == rule.id }) {
            preferences.workCaptureRules[index] = rule
        } else {
            preferences.workCaptureRules.append(rule)
        }
        if alsoSetWork {
            let classifier = rule.scope == .website
                ? Rule(host: rule.target, pathPrefix: rule.detail, category: .work)
                : Rule(appID: rule.target, windowContains: rule.detail, category: .work)
            preferences.rules.append(classifier)
        }
        if tracker.update(preferences) { dismiss() }
    }
}

private extension WorkCaptureRule {
    var label: String {
        switch scope {
        case .website: "网页"
        case .application: windowOCR ? "窗口 OCR" : "原生 App"
        case .conversation: "客户会话"
        }
    }
}
