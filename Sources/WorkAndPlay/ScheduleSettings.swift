import SwiftUI
import TimeCore

struct ScheduleSettings: View {
    @ObservedObject var tracker: Tracker
    @State private var weekday = DayOfWeek.current
    @State private var date = Date()
    @State private var draft: ScheduleDraft?
    @State private var workdayDraft: WorkdayDraft?
    @State private var savedMessage: String?

    private var schedule: Schedule { tracker.preferences.schedule }
    private var calendar: Calendar { Tracker.localCalendar }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScheduleStatus(schedule: schedule)
                if let savedMessage {
                    Label(savedMessage, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(Color.workAccent)
                }
                weekly
                dateOverride
            }
            .padding(12)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $draft) { item in
            ScheduleEditor(draft: item, tracker: tracker) { periods in save(periods, for: item.target) }
        }
        .sheet(item: $workdayDraft) { item in
            WorkdayEditor(draft: item, tracker: tracker) { hours, scope in
                saveWorkday(hours, for: item.target, scope: scope)
            }
        }
    }

    private var weekly: some View {
        let periods = Schedule.normalized(schedule.weekdays[weekday.rawValue] ?? [])
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("每周排班").font(.headline).heading()
                Spacer()
                workdayButton(.weekday(weekday), periods: schedule.weekdays[weekday.rawValue])
            }
            Picker("选择星期", selection: $weekday) {
                ForEach(DayOfWeek.allCases) { day in
                    Text(day.title).tag(day)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 12) {
                OrdinarySummary(rest: periods)
                Spacer(minLength: 8)
                editButton(.weekday(weekday), periods: periods, title: "编辑休息时段")
            }
        }
        .padding(14)
        .workCard()
    }

    private var dateOverride: some View {
        let plan = schedule.plan(for: date, calendar: calendar)
        let key = Schedule.dayKey(date, calendar: calendar)
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("日期覆盖").font(.headline).heading()
                Spacer()
                DatePicker("覆盖日期", selection: $date, displayedComponents: .date).labelsHidden()
                if !schedule.overrides.isEmpty {
                    Menu("已设日期") {
                        ForEach(schedule.overrides.keys.sorted(), id: \.self) { key in
                            Button(key) {
                                if let chosen = date(for: key) { date = chosen }
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            Text(plan.isOverride ? "已覆盖当天的每周排班" : "当天沿用每周排班")
                .font(.caption)
                .foregroundStyle(Color.workMuted)
            OrdinarySummary(rest: plan.periods)
            HStack(spacing: 8) {
                workdayButton(.date(key), periods: plan.isOverride || !plan.periods.isEmpty ? plan.periods : nil)
                editButton(.date(key), periods: plan.periods, title: "编辑休息时段")
                Spacer(minLength: 4)
                if plan.isOverride {
                    Button("恢复每周排班") { restoreWeekly(on: key) }
                }
            }
        }
        .padding(14)
        .workCard()
    }

    private func workdayButton(_ target: ScheduleTarget, periods: [RestPeriod]?) -> some View {
        let title = target.isOverride ? "设置当天上下班" : "按上下班设置"
        return Button(title, systemImage: "calendar.badge.clock") {
            savedMessage = nil
            let existing = periods.flatMap { WorkdayHours(restPeriods: $0) }
            let scope: WorkdayScope = !target.isOverride && schedule.weekdays.isEmpty ? .everyDay : .selectedDay
            workdayDraft = WorkdayDraft(target: target, hours: existing, scope: scope)
        }
        .buttonStyle(.borderedProminent)
        .fixedSize()
    }

    private func saveWorkday(_ hours: WorkdayHours, for target: ScheduleTarget, scope: WorkdayScope) -> Bool {
        if target.isOverride { return save(hours.restPeriods, for: target) }
        guard case .weekday(let day) = target else { return false }
        var next = tracker.preferences
        let rest = hours.restPeriods
        for weekday in scope.days(including: day) {
            next.schedule.weekdays[weekday.rawValue] = rest
        }
        guard tracker.update(next) else { return false }
        savedMessage = "已保存到\(scope.title(for: day))，新记录按此排班计算。"
        return true
    }

    private func editButton(_ target: ScheduleTarget, periods: [RestPeriod], title: String) -> some View {
        Button(title, systemImage: "pencil") {
            savedMessage = nil
            draft = ScheduleDraft(target: target, periods: periods)
        }
        .buttonStyle(.bordered)
        .fixedSize()
    }

    private func save(_ periods: [RestPeriod], for target: ScheduleTarget) -> Bool {
        var next = tracker.preferences
        switch target {
        case .weekday(let day):
            next.schedule.weekdays[day.rawValue] = periods.isEmpty ? nil : periods
        case .date(let key):
            next.schedule.overrides[key] = periods
        }
        guard tracker.update(next) else { return false }
        savedMessage = "已保存\(target.title)的排班，从现在起生效。"
        return true
    }

    private func restoreWeekly(on key: String) {
        var next = tracker.preferences
        next.schedule.overrides.removeValue(forKey: key)
        savedMessage = tracker.update(next) ? "\(key) 已恢复每周排班。" : nil
    }

    private func date(for key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

private struct ScheduleStatus: View {
    let schedule: Schedule

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let calendar = Tracker.localCalendar
            let now = context.date
            let today = schedule.plan(for: now, calendar: calendar)
            let active = schedule.activeRestPeriod(at: now, calendar: calendar)
            VStack(alignment: .leading, spacing: 8) {
                Label(active == nil ? "当前是普通时段" : "当前是休息时段",
                      systemImage: active == nil ? "clock" : "moon.circle")
                    .font(.headline)
                    .foregroundStyle(active == nil ? Color.workInk : Color.workAccent)
                HStack(alignment: .firstTextBaseline) {
                    Text(today.isOverride ? "今日 · 日期覆盖" : "今日 · 每周排班")
                        .font(.callout.weight(.medium))
                    OrdinarySummary(rest: today.periods)
                }
                Text("普通时段内的有效工作计入普通工时，其他时段的有效工作计入加班。")
                    .font(.caption)
                    .foregroundStyle(Color.workMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.workAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
        }
    }
}

private struct OrdinarySummary: View {
    let rest: [RestPeriod]

    var body: some View {
        let ordinary = Schedule.complement(of: rest)
        Text(summary(ordinary))
            .font(.callout.monospacedDigit())
            .foregroundStyle(Color.workMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func summary(_ ordinary: [RestPeriod]) -> String {
        if rest.isEmpty { return "全天普通时段" }
        if ordinary.isEmpty { return "全天休息" }
        return "普通时段 " + ordinary.map(\.description).joined(separator: "、")
    }
}

private enum DayOfWeek: Int, CaseIterable, Identifiable {
    case monday = 2, tuesday, wednesday, thursday, friday, saturday, sunday = 1

    var id: Self { self }

    var title: String { ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][rawValue - 1] }

    static var current: Self {
        Self(rawValue: Tracker.localCalendar.component(.weekday, from: .now)) ?? .monday
    }
}

private enum ScheduleTarget {
    case weekday(DayOfWeek)
    case date(String)

    var title: String {
        switch self {
        case .weekday(let day): day.title
        case .date(let key): key
        }
    }

    var isOverride: Bool {
        if case .date = self { return true }
        return false
    }
}

private struct ScheduleDraft: Identifiable {
    let id = UUID()
    let target: ScheduleTarget
    let periods: [RestPeriod]
}

private struct ScheduleEditor: View {
    let draft: ScheduleDraft
    @ObservedObject var tracker: Tracker
    let save: ([RestPeriod]) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [EditablePeriod]

    init(draft: ScheduleDraft, tracker: Tracker, save: @escaping ([RestPeriod]) -> Bool) {
        self.draft = draft
        self.tracker = tracker
        self.save = save
        _rows = State(initialValue: draft.periods.map { EditablePeriod(start: $0.start, end: $0.end) })
    }

    private var valid: Bool { rows.allSatisfy { $0.period.valid } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.target.isOverride ? "编辑 \(draft.target.title) 的排班" : "编辑\(draft.target.title)排班")
                .font(.title2.bold())
                .heading()

            if rows.isEmpty {
                Text(draft.target.isOverride ? "保存后，这一天为全天普通时段。" : "这一天暂无休息时段。")
                    .foregroundStyle(Color.workMuted)
            } else {
                ViewThatFits(in: .vertical) {
                    timeRows
                    ScrollView { timeRows }
                }
                .frame(maxHeight: 248)
            }

            HStack {
                Button("添加时段", systemImage: "plus", action: addPeriod)
                Button("设为全天休息") { rows = [EditablePeriod(start: 0, end: 1440)] }
                if !rows.isEmpty { Button("清除休息时段") { rows = [] } }
            }
            Text(valid
                 ? "重叠或相邻的时段会合并。跨午夜可分别设在前后两天。"
                 : "结束时间必须晚于开始时间。跨午夜请拆到两天。")
                .font(.caption)
                .foregroundStyle(valid ? Color.workMuted : .red)
            if let error = tracker.errorMessage {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存排班") {
                    if save(Schedule.normalized(rows.map(\.period))) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(21)
        .frame(width: 530)
    }

    private var timeRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($rows) { $row in
                HStack(spacing: 10) {
                    Text("开始")
                    DatePicker("开始时间", selection: clock($row.start), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Text("结束")
                    if row.end < 1440 {
                        DatePicker("结束时间", selection: clock($row.end), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    } else {
                        Text("24:00")
                            .monospacedDigit()
                            .frame(minWidth: 52)
                    }
                    Toggle("到 24:00", isOn: Binding(
                        get: { row.end == 1440 },
                        set: { row.end = $0 ? 1440 : 1439 }
                    ))
                    .toggleStyle(.checkbox)
                    Spacer(minLength: 3)
                    Button {
                        let id = row.id
                        rows.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("删除时段 \(row.period.description)")
                }
                .padding(9)
                .background(Color.workSidebar, in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .environment(\.calendar, Self.clockCalendar)
        .environment(\.timeZone, Self.clockCalendar.timeZone)
        .environment(\.locale, Locale(identifier: "en_GB"))
    }

    private func addPeriod() {
        let choices = [12 * 60, 18 * 60] + Array(stride(from: 0, through: 23 * 60, by: 60))
        let occupied = Schedule.normalized(rows.map(\.period))
        let start = choices.first { minute in
            !occupied.contains { minute <= $0.end && minute + 60 >= $0.start }
        } ?? 12 * 60
        rows.append(EditablePeriod(start: start, end: start + 60))
    }

    private static var clockCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func clock(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Date(timeIntervalSince1970: TimeInterval(minute.wrappedValue * 60)) },
            set: {
                let components = Self.clockCalendar.dateComponents([.hour, .minute], from: $0)
                minute.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }
}

private struct EditablePeriod: Identifiable {
    let id = UUID()
    var start: Int
    var end: Int

    var period: RestPeriod { RestPeriod(start: start, end: end) }
}

private enum WorkdayScope: Hashable {
    case selectedDay, weekdays, everyDay

    func title(for day: DayOfWeek) -> String {
        switch self {
        case .selectedDay: day.title
        case .weekdays: "周一至周五"
        case .everyDay: "每天（周一至周日）"
        }
    }

    func days(including day: DayOfWeek) -> [DayOfWeek] {
        switch self {
        case .selectedDay: [day]
        case .weekdays: [.monday, .tuesday, .wednesday, .thursday, .friday]
        case .everyDay: DayOfWeek.allCases
        }
    }
}

private struct WorkdayDraft: Identifiable {
    let id = UUID()
    let target: ScheduleTarget
    let hours: WorkdayHours?
    let scope: WorkdayScope
}

private struct WorkdayEditor: View {
    let draft: WorkdayDraft
    @ObservedObject var tracker: Tracker
    let save: (WorkdayHours, WorkdayScope) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var starts: String
    @State private var lunchStarts: String
    @State private var lunchEnds: String
    @State private var ends: String
    @State private var hasLunch: Bool
    @State private var scope: WorkdayScope

    init(draft: WorkdayDraft, tracker: Tracker, save: @escaping (WorkdayHours, WorkdayScope) -> Bool) {
        self.draft = draft
        self.tracker = tracker
        self.save = save
        let hours = draft.hours
        _starts = State(initialValue: RestPeriod.format(hours?.start ?? 540))
        _lunchStarts = State(initialValue: RestPeriod.format(hours?.lunch?.start ?? 700))
        _lunchEnds = State(initialValue: RestPeriod.format(hours?.lunch?.end ?? 810))
        _ends = State(initialValue: RestPeriod.format(hours?.end ?? 1080))
        _hasLunch = State(initialValue: hours == nil || hours?.lunch != nil)
        _scope = State(initialValue: draft.scope)
    }

    private var hours: WorkdayHours? {
        guard let start = WorkdayHours.minute(from: starts),
              let end = WorkdayHours.minute(from: ends, allowEndOfDay: true) else { return nil }
        if hasLunch {
            guard let lunchStart = WorkdayHours.minute(from: lunchStarts),
                  let lunchEnd = WorkdayHours.minute(from: lunchEnds) else { return nil }
            return WorkdayHours(start: start, end: end, lunch: RestPeriod(start: lunchStart, end: lunchEnd))
        }
        return WorkdayHours(start: start, end: end, lunch: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.target.isOverride ? "设置当天上下班" : "设置上下班时间")
                .font(.title2.bold())
                .heading()
            Text("用 24 小时制。下午 1:30 填 13:30，下午 6 点填 18:00。")
                .font(.callout)
                .foregroundStyle(Color.workMuted)

            VStack(alignment: .leading, spacing: 11) {
                timeField("上班时间", text: $starts, example: "09:00")
                Toggle("有午休", isOn: $hasLunch).toggleStyle(.checkbox)
                if hasLunch {
                    timeField("午休开始", text: $lunchStarts, example: "11:40")
                    timeField("午休结束", text: $lunchEnds, example: "13:30")
                }
                timeField("下班时间", text: $ends, example: "18:00")
            }
            .padding(13)
            .background(Color.workSidebar, in: RoundedRectangle(cornerRadius: 12))

            if case .weekday(let day) = draft.target {
                HStack(spacing: 12) {
                    Text("应用到")
                    Picker("应用到", selection: $scope) {
                        Text("仅\(day.title)").tag(WorkdayScope.selectedDay)
                        Text("周一至周五").tag(WorkdayScope.weekdays)
                        Text("每天").tag(WorkdayScope.everyDay)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Text("保存范围 · \(scope.title(for: day))")
                    .font(.caption)
                    .foregroundStyle(Color.workMuted)
            } else {
                Text("保存范围 · \(draft.target.title)")
                    .font(.caption)
                    .foregroundStyle(Color.workMuted)
            }

            if let hours {
                preview(hours)
            } else {
                Label(hasLunch ? "请按上班、午休开始、午休结束、下班的顺序填写。"
                      : "下班时间要在上班时间之后。", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if let error = tracker.errorMessage {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存排班") {
                    if let hours, save(hours, scope) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(hours == nil)
            }
        }
        .padding(22)
        .frame(width: 516)
    }

    private func timeField(_ title: String, text: Binding<String>, example: String) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 80, alignment: .leading)
            TextField(title, text: text, prompt: Text(example))
                .labelsHidden()
                .accessibilityLabel(title)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 110)
            Spacer()
        }
    }

    private func preview(_ hours: WorkdayHours) -> some View {
        let ordinary = hours.ordinaryPeriods
        let total = ordinary.reduce(0) { $0 + $1.end - $1.start }
        return VStack(alignment: .leading, spacing: 6) {
            Text("普通工时可计时段").font(.headline)
            Text(ordinary.map(\.description).joined(separator: "、"))
                .monospacedDigit()
                .font(.callout.weight(.semibold))
            Text("普通时段共 \(durationText(Double(total) * 60))。其余时段的有效工作计入加班。")
                .font(.caption)
                .foregroundStyle(Color.workMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color.workAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }
}
