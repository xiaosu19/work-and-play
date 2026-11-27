import ChromeBridge
import Foundation
import TimeCore

struct WorkCaptureSession {
    let id = UUID()
    let rule: WorkCaptureRule
    let token: String
    let browserSession: UUID?
    let started: Date
    var lastEdited: Bool?
    var lastInput = Date.distantPast
    var lastDesktopRecord = Date.distantPast
    var lastOCR = Date.distantPast

    private var attempts: [UUID: PendingWorkActivity] = [:]

    init(rule: WorkCaptureRule, token: String, browserSession: UUID?, at now: Date) {
        self.rule = rule
        self.token = token
        self.browserSession = browserSession
        started = now
    }

    var browserPermit: BrowserWorkPermit? {
        guard browserSession != nil else { return nil }
        return BrowserWorkPermit(id: id, keyword: rule.keyword)
    }

    mutating func browserActivities(_ signals: [BrowserWorkSignal], span: UUID?, at now: Date) -> [PendingWorkActivity] {
        attempts = attempts.filter { now.timeIntervalSince($0.value.activity.at) <= 6 }
        var activities: [PendingWorkActivity] = []
        for signal in signals {
            let date = Date(timeIntervalSince1970: signal.at / 1000)
            guard signal.permit == id, date >= started, (-0.05...5).contains(now.timeIntervalSince(date)) else { continue }
            let action: WorkAction
            let evidence: WorkEvidence
            let result: WorkResult
            switch signal.action {
            case .review:
                action = signal.matchedTopic ? .reviewedTopic : .reviewedPage
                result = .observed
                evidence = signal.matchedTopic ? .visibleTopic : .documentInteraction
            case .interact:
                action = .usedPage
                result = .observed
                evidence = .documentInteraction
            case .submit, .save:
                action = signal.action == .submit ? .submittedForm : .savedChanges
                result = signal.confirmed ? .confirmed : .attempted
                evidence = signal.confirmed ? .visibleFeedback : .trustedControl
            }
            let at: Date
            let workSpan: UUID
            if result == .confirmed {
                guard let attempt = attempts.removeValue(forKey: signal.id),
                      attempt.activity.action == action else { continue }
                at = attempt.activity.at
                workSpan = attempt.spanID
            } else {
                guard let span else { continue }
                at = now
                workSpan = span
            }
            let activity = WorkActivity(id: signal.id, at: at, project: rule.project, action: action,
                                        result: result, evidence: evidence)
            let pending = PendingWorkActivity(spanID: workSpan, activity: activity)
            if result == .attempted { attempts[signal.id] = pending }
            activities.append(pending)
        }
        return activities
    }
}
