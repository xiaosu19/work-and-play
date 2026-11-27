import AppKit
import SwiftUI
import TimeCore

private enum WorkspaceAppearance: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"

    var id: Self { self }
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview, digest, preferences

    var id: Self { self }
    var title: String {
        switch self {
        case .overview: "时间总览"
        case .digest: "记录与接口"
        case .preferences: "设置"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .digest: "doc.text"
        case .preferences: "slider.horizontal.3"
        }
    }
}

@MainActor
final class AppNavigation: ObservableObject {
    @Published var section: AppSection = .overview
    @Published var settingsTab = "tracking"
}

struct WorkspaceView: View {
    @ObservedObject var tracker: Tracker
    @ObservedObject var navigation: AppNavigation
    @AppStorage("workspaceAppearance") private var appearance = WorkspaceAppearance.system

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color.workBorder)
            ZStack {
                ReportView(tracker: tracker, openBrowserSetup: {
                    navigation.settingsTab = "tracking"
                    navigation.section = .preferences
                })
                    .opacity(navigation.section == .overview ? 1 : 0)
                    .allowsHitTesting(navigation.section == .overview)
                    .accessibilityHidden(navigation.section != .overview)
                if navigation.section == .digest {
                    DigestView(tracker: tracker, openSettings: {
                        navigation.settingsTab = "capture"
                        navigation.section = .preferences
                    })
                }
                if navigation.section == .preferences {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("设置")
                                .font(.system(size: 30, weight: .semibold))
                                .heading()
                            Spacer()
                            Picker("窗口外观", selection: $appearance) {
                                ForEach(WorkspaceAppearance.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 185)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 19)
                        PreferencesView(tracker: tracker, tab: $navigation.settingsTab)
                            .background(Color.workSurface, in: RoundedRectangle(cornerRadius: 20))
                            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.workBorder))
                            .padding([.horizontal, .bottom], 24)
                    }
                    .background(Color.workCanvas)
                }
            }
        }
        .foregroundStyle(Color.workInk)
        .tint(.workAccent)
        .background(Color.workCanvas)
        .preferredColorScheme(appearance.scheme)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.adaptive(0xFFFFFF, 0x14212A))
                    .frame(width: 38, height: 38)
                    .background(Color.workAccent, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                Text("工时簿")
                    .font(.system(size: 19, weight: .semibold))
            }
            .padding(.bottom, 28)

            ForEach(AppSection.allCases) { section in
                Button {
                    navigation.section = section
                } label: {
                    Label(section.title, systemImage: section.symbol)
                        .font(.system(size: 13, weight: navigation.section == section ? .semibold : .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 10)
                        .foregroundStyle(navigation.section == section ? Color.workAccent : Color.workInk)
                        .background(navigation.section == section ? Color.workAccent.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(navigation.section == section ? [.isSelected] : [])
                .padding(.bottom, 4)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 7) {
                Label(tracker.preferences.paused ? "已暂停" : "本机记录", systemImage: tracker.preferences.paused ? "pause.circle" : "internaldrive")
                    .font(.system(size: 12, weight: .medium))
                Text(tracker.status)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                Text(tracker.precision)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.workMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let status = tracker.workCaptureStatus {
                    Text(status).font(.system(size: 11)).foregroundStyle(Color.workAccent)
                        .lineLimit(2)
                }
                Button(tracker.preferences.paused ? "继续统计" : "暂停统计", action: tracker.togglePause)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 3)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.workSurface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.workBorder))
        }
        .padding(15)
        .padding(.top, 11)
        .frame(width: 170)
        .background(Color.workSidebar)
    }
}

extension Color {
    static let workCanvas = adaptive(0xF0F5F5, 0x101A21)
    static let workSidebar = adaptive(0xE7EFF0, 0x14212A)
    static let workSurface = adaptive(0xFCFEFE, 0x1A2932)
    static let workInk = adaptive(0x172A34, 0xE8F2F4)
    static let workMuted = adaptive(0x526771, 0xAAC0C8)
    static let workBorder = adaptive(0xD8E4E6, 0x334753)
    static let workAccent = adaptive(0x127168, 0x78CFC0)

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        func rgb(_ value: UInt32) -> NSColor {
            NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                    blue: Double(value & 255) / 255, alpha: 1)
        }

        return Color(nsColor: NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }
}

extension Bucket {
    var color: Color {
        switch self {
        case .regular: .adaptive(0x157A6D, 0x73CEBA)
        case .overtime: .adaptive(0x5263AE, 0xA6B3FC)
        case .entertainment: .adaptive(0xA45A2D, 0xEAB287)
        case .review: .adaptive(0x657983, 0xA7BDC6)
        }
    }

    var symbol: String {
        switch self {
        case .regular: "briefcase"
        case .overtime: "clock.badge.exclamationmark"
        case .entertainment: "play.circle"
        case .review: "questionmark.circle"
        }
    }
}

extension View {
    func heading() -> some View { accessibilityAddTraits(.isHeader) }

    func workCard() -> some View {
        background(Color.workSurface, in: RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(Color.workBorder).allowsHitTesting(false))
    }
}
