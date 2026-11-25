import AppKit
import SwiftUI
import TimeCore

@main
struct WorkAndPlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var navigation = AppNavigation()

    var body: some Scene {
        Window("工时簿", id: "main") {
            WorkspaceView(tracker: delegate.tracker, navigation: navigation)
                .frame(minWidth: 840, minHeight: 620)
        }
        .defaultSize(width: 1060, height: 800)
        .defaultPosition(.center)

        MenuBarExtra {
            TrackerMenu(tracker: delegate.tracker, navigation: navigation)
        } label: {
            MenuLabel(tracker: delegate.tracker)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let tracker = Tracker()

    func applicationDidFinishLaunching(_ notification: Notification) { tracker.start() }
    func applicationWillTerminate(_ notification: Notification) { tracker.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct MenuLabel: View {
    @ObservedObject var tracker: Tracker

    var body: some View {
        Label(tracker.status, systemImage: symbol)
            .labelStyle(.iconOnly)
            .help(tracker.status)
    }

    private var symbol: String {
        if tracker.preferences.paused { return "pause.circle" }
        if tracker.status.hasPrefix(Bucket.regular.title) { return "briefcase" }
        if tracker.status.hasPrefix(Bucket.overtime.title) { return "clock.badge.exclamationmark" }
        if tracker.status.hasPrefix(Bucket.entertainment.title) { return "play.circle" }
        if tracker.status == "休息中" { return "moon" }
        return "clock"
    }
}

private struct TrackerMenu: View {
    @ObservedObject var tracker: Tracker
    @ObservedObject var navigation: AppNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(tracker.status)
        Text("识别精度 · \(tracker.precision)")
        if let error = tracker.errorMessage { Text(error) }
        Divider()
        Button(tracker.preferences.paused ? "继续统计" : "暂停统计", action: tracker.togglePause)
        Button("打开日报") {
            tracker.refreshReport()
            open(.overview)
        }
        .keyboardShortcut("d")
        Button("设置…") { open(.preferences) }
            .keyboardShortcut(",")
        Divider()
        Button("退出工时簿") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ section: AppSection) {
        navigation.section = section
        openWindow(id: "main")
        NSApp.activate()
    }
}

extension ActivityCategory {
    static let displayCases: [Self] = [.work, .entertainment]

    var title: String {
        switch self {
        case .work: "工作"
        case .entertainment, .unclassified: "摸鱼"
        }
    }
}

extension ActivityKind {
    var title: String { self == .reading ? "阅读" : "操作" }
}

extension Bucket {
    static let displayCases: [Self] = [.regular, .overtime, .entertainment]

    var title: String {
        switch self {
        case .regular: "普通工时"
        case .overtime: "加班"
        case .entertainment, .review: "摸鱼"
        }
    }

}

func durationText(_ interval: TimeInterval) -> String {
    let seconds = Int(interval.rounded())
    if interval > 0 && seconds == 0 { return "不到 1 秒" }
    let units = [(seconds / 3600, "小时"), (seconds % 3600 / 60, "分"), (seconds % 60, "秒")]
    let parts = units.compactMap { value, symbol in value > 0 ? "\(value) \(symbol)" : nil }
    return parts.isEmpty ? "0 秒" : parts.joined(separator: " ")
}
