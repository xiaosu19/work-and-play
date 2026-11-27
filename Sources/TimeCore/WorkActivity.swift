import Foundation

public enum WorkCaptureScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case website, application, conversation
    public var id: Self { self }
}

public struct WorkCaptureRule: Codable, Identifiable, Equatable, Sendable {
    public static let messagingApps: Set<String> = ["com.tencent.xinwechat", "com.tencent.weworkmac"]
    private static let browsers: Set<String> = ["com.google.chrome", "com.microsoft.edgemac"]

    public var id = UUID()
    public var scope: WorkCaptureScope = .website
    public var target = ""
    public var detail = ""
    public var project = ""
    public var keyword = ""
    public var windowOCR = false

    public init() {}

    public var valid: Bool {
        guard !project.isEmpty, [target, detail, project, keyword].allSatisfy({
            $0.utf8.count <= 180 && $0.rangeOfCharacter(from: .controlCharacters) == nil
        }) else { return false }
        switch scope {
        case .website:
            return !windowOCR && Privacy.host(target) != nil && !target.contains("..")
                && (detail.isEmpty || Privacy.path(detail) == detail)
        case .application:
            return !Self.browsers.contains(target.lowercased()) && !Self.messagingApps.contains(target.lowercased())
                && Self.validBundle(target) && (!windowOCR || (!detail.isEmpty && !keyword.isEmpty))
        case .conversation:
            let title = detail.lowercased()
            return !windowOCR && Self.messagingApps.contains(target.lowercased())
                && !title.isEmpty && !["微信", "企业微信", "wechat", "wecom", "wxwork"].contains(title)
        }
    }

    public func matches(_ identity: ActivityIdentity) -> Bool {
        guard valid else { return false }
        switch scope {
        case .website:
            guard Self.browsers.contains(identity.appID.lowercased()),
                  identity.host?.lowercased() == target.lowercased(), let path = identity.path else { return false }
            let prefix = detail.hasSuffix("/") ? detail : detail + "/"
            return detail.isEmpty || path == detail || path.hasPrefix(prefix)
        case .application, .conversation:
            guard identity.host == nil, identity.appID.caseInsensitiveCompare(target) == .orderedSame else { return false }
            return detail.isEmpty || identity.window == detail
        }
    }

    public static func authorized(through rules: [Self], for identity: ActivityIdentity, category: ActivityCategory) -> Self? {
        guard category == .work else { return nil }
        return rules.filter { $0.matches(identity) }.reduce(nil as Self?) { previous, rule in
            guard let previous else { return rule }
            return previous.detail.count > rule.detail.count ? previous : rule
        }
    }

    private static func validBundle(_ id: String) -> Bool {
        id.range(of: #"^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$"#, options: .regularExpression) != nil
    }
}

public enum WorkAction: String, Codable, Sendable {
    case reviewedPage, reviewedTopic, usedPage, submittedForm, savedChanges
    case usedApplication, editedDocument, customerConversation, matchedWindowText, manualNote
}

public enum WorkResult: String, Codable, Sendable {
    case observed, attempted, confirmed, reported
}

public enum WorkEvidence: String, Codable, Sendable {
    case documentInteraction, visibleTopic, trustedControl, visibleFeedback
    case foregroundInput, editedWindow, selectedConversation, windowOCR, userNote
}

public struct WorkActivity: Codable, Equatable, Sendable {
    public let id: UUID
    public let at: Date
    public let project: String
    public let action: WorkAction
    public let result: WorkResult
    public let evidence: WorkEvidence

    public init(id: UUID = UUID(), at: Date, project: String, action: WorkAction, result: WorkResult, evidence: WorkEvidence) {
        self.id = id
        self.at = at
        self.project = project
        self.action = action
        self.result = result
        self.evidence = evidence
    }

    public var valid: Bool {
        guard at.timeIntervalSince1970.isFinite, !project.isEmpty, project.utf8.count <= 180,
              project.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        switch (action, result, evidence) {
        case (.reviewedPage, .observed, .documentInteraction), (.reviewedTopic, .observed, .visibleTopic),
             (.usedPage, .observed, .documentInteraction),
             (.submittedForm, .attempted, .trustedControl), (.savedChanges, .attempted, .trustedControl),
             (.submittedForm, .confirmed, .visibleFeedback), (.savedChanges, .confirmed, .visibleFeedback),
             (.usedApplication, .observed, .foregroundInput), (.editedDocument, .observed, .editedWindow),
             (.customerConversation, .observed, .selectedConversation), (.matchedWindowText, .observed, .windowOCR),
             (.manualNote, .reported, .userNote):
            return true
        default: return false
        }
    }

    public var description: String {
        switch action {
        case .reviewedPage: "查看「\(project)」页面内容"
        case .reviewedTopic: "查看「\(project)」的相关页面章节"
        case .usedPage: "操作「\(project)」工作页面"
        case .submittedForm: result == .confirmed ? "提交「\(project)」表单成功" : "尝试提交「\(project)」表单"
        case .savedChanges: result == .confirmed ? "保存「\(project)」更改成功" : "尝试保存「\(project)」更改"
        case .usedApplication: "操作「\(project)」相关应用"
        case .editedDocument: "编辑「\(project)」相关文档"
        case .customerConversation: "在「\(project)」客户会话中操作"
        case .matchedWindowText: "查看「\(project)」窗口，匹配了授权的内容关键词"
        case .manualNote: "补记「\(project)」工作"
        }
    }
}

public struct PendingWorkActivity: Sendable {
    public let spanID: UUID
    public let activity: WorkActivity

    public init(spanID: UUID, activity: WorkActivity) {
        self.spanID = spanID
        self.activity = activity
    }
}
