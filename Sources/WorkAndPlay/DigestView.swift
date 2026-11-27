import AppKit
import SwiftUI
import TimeCore
import TimeStore
import UniformTypeIdentifiers

struct DigestView: View {
    @ObservedObject var tracker: Tracker
    let openSettings: () -> Void

    @State private var cadence: ReportCadence = .day
    @State private var channel: ReportChannel = .work
    @State private var date = Date()
    @State private var records: [WorkActivityRecord] = []
    @State private var work: WorkReportInput?
    @State private var leisure: LeisureReportInput?
    @State private var editing: WorkActivityRecord?
    @State private var segment: ReportEntry?
    @State private var message: String?
    @State private var shared = false
    @State private var export: ReportDocument?
    @State private var exporting = false
    @State private var page = 0

    private let pageSize = 16
    private var selection: DigestPeriod? {
        DigestPeriod(cadence, including: Schedule.dayKey(date, calendar: Tracker.localCalendar))
    }
    private var accent: Color { channel == .work ? Bucket.regular.color : Bucket.entertainment.color }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if channel == .work, let work { workCard(work) }
                if channel == .leisure, let leisure { leisureCard(leisure) }
                exportCard
            }
            .padding(24)
            .frame(maxWidth: 1140)
            .frame(maxWidth: .infinity)
        }
        .background(Color.workCanvas)
        .onAppear { tracker.refreshReport(); load() }
        .onChange(of: selection) { _, _ in page = 0; load() }
        .onChange(of: channel) { _, _ in message = nil; load() }
        .onChange(of: tracker.revision) { _, _ in load(resetMessage: false) }
        .sheet(item: $editing) { record in
            if let day = day(of: record) {
                WorkActivityEditor(tracker: tracker, record: record, day: day)
            }
        }
        .sheet(item: $segment) { SegmentOperations(tracker: tracker, entry: $0) }
        .fileExporter(isPresented: $exporting, document: export, contentType: .json,
                      defaultFilename: exportFilename) { result in
            switch result {
            case .success: message = "已导出 JSON"
            case .failure: message = "无法写入文件，请换一个保存位置。"
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("记录与接口").font(.system(size: 33, weight: .semibold)).heading()
                Spacer()
                Picker("记录周期", selection: $cadence) {
                    Text("日").tag(ReportCadence.day)
                    Text("周").tag(ReportCadence.week)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 152)
            }
            HStack {
                Picker("数据范围", selection: $channel) {
                    Text("工作记录").tag(ReportChannel.work)
                    Text("摸鱼数据").tag(ReportChannel.leisure)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 195)
                Spacer()
                DatePicker("记录日期", selection: $date, displayedComponents: .date)
                    .labelsHidden()
                Button("今天") { date = .now }.controlSize(.small)
            }
        }
    }

    private func workCard(_ report: WorkReportInput) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                Text("工作合计").font(.headline)
                Text(durationText(Double(report.workSeconds))).font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(accent)
                Spacer()
                Text(periodLabel).font(.caption.monospacedDigit()).foregroundStyle(Color.workMuted)
            }
            HStack(spacing: 18) {
                Label("普通工时 \(durationText(Double(report.regularSeconds)))", systemImage: "briefcase")
                Label("加班 \(durationText(Double(report.overtimeSeconds)))", systemImage: "clock.badge.exclamationmark")
            }
            .font(.caption)
            .foregroundStyle(Color.workMuted)
            Divider()
            HStack {
                Text("操作描述").font(.headline)
                Spacer()
                Text("\(report.events.count) 条已纳入工作 JSON").font(.caption).foregroundStyle(Color.workMuted)
            }
            if records.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("这段时间暂无详细操作描述").font(.headline)
                    Text("基础时间片段会自动保存。授权来源后，可补充更详细的操作。")
                        .font(.callout).foregroundStyle(Color.workMuted)
                    Button("打开操作描述设置", action: openSettings)
                }
                .padding(.vertical, 9)
            } else {
                let pages = max(1, (records.count + pageSize - 1) / pageSize)
                ForEach(records.dropFirst(min(page, pages - 1) * pageSize).prefix(pageSize)) { record in
                    activityRow(record)
                    Divider().overlay(Color.workBorder.opacity(0.6))
                }
                if pages > 1 {
                    HStack {
                        Spacer()
                        Button("上一页") { page -= 1 }.disabled(page == 0)
                        Text("第 \(page + 1) 页，共 \(pages) 页").font(.caption.monospacedDigit())
                        Button("下一页") { page += 1 }.disabled(page + 1 >= pages)
                    }
                }
            }
        }
        .padding(17)
        .workCard()
    }

    private func leisureCard(_ report: LeisureReportInput) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                Text("摸鱼合计").font(.headline)
                Text(durationText(Double(report.leisureSeconds))).font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(accent)
                Spacer()
                Text(periodLabel).font(.caption.monospacedDigit()).foregroundStyle(Color.workMuted)
            }
            if report.sources.isEmpty {
                Text("这个周期没有摸鱼记录。").foregroundStyle(Color.workMuted)
            } else {
                ForEach(report.sources) { source in
                    Divider()
                    HStack {
                        Text(source.label)
                        Spacer()
                        Text("\(source.segmentCount) 段").foregroundStyle(Color.workMuted)
                        Text(durationText(Double(source.seconds))).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
        .padding(17)
        .workCard()
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(channel == .work ? "工作接口" : "摸鱼接口", systemImage: "curlybraces")
                    .font(.headline)
                Spacer()
                Button("显示 JSON 文件") { revealOperationJSON() }
                Button("导出 JSON") { exportJSON() }
                Button(shared ? "撤销命令行授权" : "授权命令行读取") { changeShare() }
                    .buttonStyle(.borderedProminent)
            }
            Text("按天自动保存本机 JSON。")
                .font(.caption).foregroundStyle(Color.workMuted)
            Text(shared ? command : "临时命令行快照在 24 小时后到期。")
                .font(shared ? .caption.monospaced() : .caption)
                .foregroundStyle(Color.workMuted)
                .textSelection(.enabled)
            if channel == .work {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text("AI 接入").font(.subheadline.weight(.semibold))
                    Text("本机 MCP 提供工作日、周数据，由你的 AI 生成报告。")
                        .font(.caption).foregroundStyle(Color.workMuted)
                    Spacer()
                    Button("复制 MCP 配置") { copyMCPConfiguration() }
                }
            }
            if let error = tracker.operationJSONError { Text(error).font(.caption).foregroundStyle(.red) }
            if let message { Text(message).font(.caption).foregroundStyle(Color.workMuted) }
        }
        .padding(16)
        .workCard()
    }

    private func activityRow(_ record: WorkActivityRecord) -> some View {
        HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 2).fill(record.excluded ? Color.workBorder : accent)
                .frame(width: 3, height: 34).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.description).fontWeight(.medium)
                let zone = TimeZone(identifier: record.timeZone) ?? .current
                let clock = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)
                Text("\(record.activity.at.formatted(clock)) · \(record.source)")
                    .font(.caption.monospacedDigit()).foregroundStyle(Color.workMuted)
            }
            Spacer()
            Text(record.excluded ? "已排除" : record.activity.result.title)
                .font(.caption).foregroundStyle(Color.workMuted)
            Button("片段 \(record.segmentID)") { segment = tracker.fragment(id: record.segmentID) }.controlSize(.small)
            Button("修正") { editing = record }.controlSize(.small)
        }
    }

    private var periodLabel: String {
        guard let selection else { return "" }
        return selection.cadence == .day ? selection.startDay : "\(selection.startDay) – \(selection.endDay)"
    }

    private var exportFilename: String {
        "工时簿-\(channel == .work ? "工作" : "摸鱼")-\(cadence == .day ? "日" : "周")-\(selection?.startDay ?? "")"
    }

    private var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/WorkAndPlayReport").path
    }

    private var command: String {
        let quoted = "'" + helperPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(quoted) \(channel.rawValue) \(cadence.rawValue) \(selection?.startDay ?? "")"
    }

    private func day(of record: WorkActivityRecord) -> String? {
        guard let zone = TimeZone(identifier: record.timeZone) else { return nil }
        var calendar = Tracker.localCalendar
        calendar.timeZone = zone
        return Schedule.dayKey(record.activity.at, calendar: calendar)
    }

    private func load(resetMessage: Bool = true) {
        guard let selection else { return }
        records = tracker.workActivities(dayRange: selection.days)
        work = WorkReportInput(period: selection, totals: tracker.totals(dayRange: selection.days), activities: records)
        leisure = LeisureReportInput(period: selection, sources: tracker.sourceTotals(dayRange: selection.days, bucket: .entertainment))
        page = min(page, max(0, (records.count + pageSize - 1) / pageSize - 1))
        shared = (try? WorkReportShare.read(channel, period: selection, in: tracker.reportShareDirectory)) != nil
        if resetMessage { message = nil }
    }

    private func selectedData() throws -> Data {
        guard let selection else { throw WorkReportShare.ShareError.unavailable }
        let segments = tracker.report(dayRange: selection.days).entries
        switch channel {
        case .work:
            let input = WorkReportInput(period: selection, totals: tracker.totals(dayRange: selection.days),
                activities: tracker.workActivities(dayRange: selection.days), segments: segments)
            return try WorkReportShare.json(input)
        case .leisure:
            let input = LeisureReportInput(period: selection,
                sources: tracker.sourceTotals(dayRange: selection.days, bucket: .entertainment), segments: segments)
            return try WorkReportShare.json(input)
        }
    }

    private func exportJSON() {
        do {
            export = ReportDocument(data: try selectedData())
            exporting = true
        } catch { message = "无法生成 JSON，请重新打开报告。" }
    }

    private func changeShare() {
        guard let selection else { return }
        do {
            if shared {
                try WorkReportShare.revoke(channel, period: selection, in: tracker.reportShareDirectory)
                shared = false
                message = "已撤销命令行授权"
            } else {
                try WorkReportShare.publish(selectedData(), channel: channel, period: selection, in: tracker.reportShareDirectory)
                shared = true
                message = "已授权当前 JSON 快照"
            }
        } catch { message = "无法更新本机接口，请检查工时簿的数据目录。" }
    }

    private func revealOperationJSON() {
        tracker.refreshReport()
        tracker.syncOperationJSON(force: true)
        let directory = OperationJSON.folder(for: channel)
        if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else {
            message = "本机 JSON 文件夹尚未生成。"
        }
    }

    private func copyMCPConfiguration() {
        let server: [String: Any] = ["command": helperPath, "args": ["mcp"]]
        let configuration = ["mcpServers": ["workandplay": server]]
        do {
            let data = try JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .withoutEscapingSlashes])
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
            message = "已复制配置，可添加到支持本机 MCP 的 AI 客户端。"
        } catch { message = "无法复制 MCP 配置。" }
    }

}

struct SegmentOperations: View {
    @ObservedObject var tracker: Tracker
    let entry: ReportEntry
    @Environment(\.dismiss) private var dismiss
    @State private var records: [WorkActivityRecord] = []
    @State private var editing: WorkActivityRecord?
    @State private var project = ""
    @State private var note = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("操作描述").font(.title2.bold())
            Text("\(entry.label) · \(entry.bucket.title) · 片段 \(entry.id)").font(.headline)
            let clock = Date.FormatStyle(date: .omitted, time: .standard,
                                         timeZone: TimeZone(identifier: entry.timeZoneID) ?? .current)
            Text("\(entry.day)  \(entry.start.formatted(clock)) – \(entry.end.formatted(clock))")
                .font(.caption.monospacedDigit()).foregroundStyle(Color.workMuted)
            if records.isEmpty {
                Text("此片段暂无操作描述。").foregroundStyle(Color.workMuted)
            } else {
                List(records) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.description)
                            Text(record.excluded ? "已排除" : record.activity.result.title)
                                .font(.caption).foregroundStyle(Color.workMuted)
                        }
                        Spacer()
                        Button("修正") { editing = record }
                    }
                    .padding(.vertical, 3)
                }
                .frame(height: 170)
            }
            Divider()
            TextField("项目或客户别名", text: $project)
            TextField("补记完成的操作与结果", text: $note)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存补记", action: save).keyboardShortcut(.defaultAction)
                    .disabled(project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || project.utf8.count > 180 || note.utf8.count > 600)
            }
        }
        .padding(22)
        .frame(width: 500)
        .onAppear(perform: load)
        .onChange(of: tracker.revision) { _, _ in load() }
        .sheet(item: $editing) { WorkActivityEditor(tracker: tracker, record: $0, day: entry.day) }
    }

    private func load() {
        records = tracker.workActivities(dayRange: entry.day...entry.day, segmentID: entry.id)
        if project.isEmpty { project = records.first?.activity.project ?? "" }
    }

    private func save() {
        do {
            try tracker.addWorkNote(note.trimmingCharacters(in: .whitespacesAndNewlines),
                                    project: project.trimmingCharacters(in: .whitespacesAndNewlines), to: entry)
            note = ""
            error = nil
        } catch { self.error = "无法保存补记。请确认片段仍属于工作。" }
    }
}

private struct ReportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

extension WorkResult {
    var title: String {
        switch self {
        case .observed: "已观察"
        case .attempted: "待确认"
        case .confirmed: "已确认"
        case .reported: "手动补记"
        }
    }
}

struct WorkActivityEditor: View {
    @ObservedObject var tracker: Tracker
    @Environment(\.dismiss) private var dismiss
    let record: WorkActivityRecord
    let day: String
    @State private var text = ""
    @State private var excluded = false
    @State private var confirmingDelete = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("修正操作描述").font(.title2.bold())
            Text("片段 \(record.segmentID) · \(record.source) · \(record.activity.result.title)")
                .font(.caption).foregroundStyle(Color.workMuted)
            TextField("操作描述", text: $text)
            Toggle("从日报、周报和工作接口排除此条", isOn: $excluded)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("删除描述", role: .destructive) { confirmingDelete = true }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 600)
            }
        }
        .padding(22)
        .frame(width: 470)
        .onAppear { text = record.description; excluded = record.excluded }
        .alert("删除这条操作描述？", isPresented: $confirmingDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                do { try tracker.removeWorkActivity(record, on: day); dismiss() }
                catch { self.error = "无法删除这条描述。" }
            }
        }
    }

    private func save() {
        do {
            let note = text == record.activity.description ? nil : text
            try tracker.reviseWorkActivity(record, on: day, note: note, excluded: excluded)
            dismiss()
        } catch { self.error = "无法保存这次修正。" }
    }
}
