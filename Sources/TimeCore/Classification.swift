import Foundation

public enum ActivityCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case work, entertainment, unclassified
    public var id: Self { self }
}

public enum ActivityKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case interactive, reading
    public var id: Self { self }
}

public struct ActivityIdentity: Equatable, Sendable {
    public var appID: String
    public var appName: String
    public var window: String?
    public var host: String?
    public var path: String?
    public var appCategory: String?

    public init(appID: String, appName: String, window: String? = nil, host: String? = nil,
                path: String? = nil, appCategory: String? = nil) {
        self.appID = appID
        self.appName = appName
        self.window = window
        self.host = host
        self.path = path
        self.appCategory = appCategory
    }
}

public struct Rule: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var appID = ""
    public var windowContains = ""
    public var host = ""
    public var pathPrefix = ""
    public var project = ""
    public var category: ActivityCategory = .unclassified
    public var kind: ActivityKind = .interactive

    public init(appID: String = "", windowContains: String = "", host: String = "", pathPrefix: String = "",
                project: String = "", category: ActivityCategory = .unclassified, kind: ActivityKind = .interactive) {
        self.appID = appID; self.windowContains = windowContains; self.host = host
        self.pathPrefix = pathPrefix; self.project = project; self.category = category; self.kind = kind
    }

    public var valid: Bool {
        let fields = [appID, windowContains, host, pathPrefix, project]
        guard fields.contains(where: { !$0.isEmpty }),
              fields.allSatisfy({ $0.utf8.count <= 512 && $0.rangeOfCharacter(from: .controlCharacters) == nil })
        else { return false }
        let validHost: Bool
        if let suffix = wildcardDomain {
            validHost = Privacy.host(String(suffix)) != nil && !suffix.contains("..")
        } else {
            validHost = host.isEmpty || Privacy.host(host) != nil
        }
        return validHost
            && (pathPrefix.isEmpty || (!host.isEmpty && Privacy.path(pathPrefix) == pathPrefix))
    }

    public var scope: String {
        [appID, windowContains, host + pathPrefix, project].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public var isWebsiteOnly: Bool {
        !host.isEmpty && appID.isEmpty && windowContains.isEmpty && pathPrefix.isEmpty && project.isEmpty
    }

    public var isApplicationOnly: Bool {
        !appID.isEmpty && host.isEmpty && windowContains.isEmpty && pathPrefix.isEmpty && project.isEmpty
    }

    private func match(_ identity: ActivityIdentity) -> Bool {
        let page = identity.path ?? ""
        let pathMatches = pathPrefix.isEmpty || page == pathPrefix
            || page.hasPrefix(pathPrefix.hasSuffix("/") ? pathPrefix : pathPrefix + "/")
        return (appID.isEmpty || appID.caseInsensitiveCompare(identity.appID) == .orderedSame)
            && matchesHost(identity.host)
            && pathMatches
            && (windowContains.isEmpty || identity.window?.localizedCaseInsensitiveContains(windowContains) == true)
            && (project.isEmpty || [identity.window, identity.path].contains {
                $0?.localizedCaseInsensitiveContains(project) == true
            })
    }

    private var wildcardDomain: Substring? {
        guard host.hasPrefix("*") else { return nil }
        let suffix = host.dropFirst()
        return suffix.hasPrefix(".") ? suffix.dropFirst() : suffix
    }

    private func matchesHost(_ website: String?) -> Bool {
        if host.isEmpty { return true }
        guard let website = website?.lowercased() else { return false }
        if let wildcardDomain {
            let suffix = wildcardDomain.lowercased()
            return website == suffix || website.hasSuffix("." + suffix)
        }
        return website == host.lowercased()
    }

    private var specificity: [Int] {
        let contextual = [windowContains, pathPrefix, project].filter { !$0.isEmpty }.count
        let wildcard = wildcardDomain
        let domainPriority = host.isEmpty ? 0 : (wildcard == nil ? 2 : 1)
        return [contextual, domainPriority, wildcard?.count ?? 0, appID.isEmpty ? 0 : 1,
                pathPrefix.count + windowContains.count + project.count]
    }

    private var basis: ClassificationBasis {
        if !project.isEmpty { return .project }
        if !pathPrefix.isEmpty { return .path }
        if !windowContains.isEmpty { return .window }
        if !host.isEmpty { return .domain }
        return .app
    }

    public static func classify(_ identity: ActivityIdentity, using rules: [Rule],
                                fallbackBasis: ClassificationBasis = .none) -> Classification {
        let rule = rules.filter { $0.valid && $0.match(identity) }
            .reduce(nil as Rule?) { previous, next in
                guard let previous else { return next }
                return next.specificity.lexicographicallyPrecedes(previous.specificity) ? previous : next
            }
        let automatic = rule == nil ? AutomaticClassification.match(identity) : nil
        return Classification(
            category: rule?.category ?? automatic?.category ?? .unclassified,
            kind: rule?.kind ?? automatic?.kind ?? .interactive,
            label: identity.host ?? identity.appName,
            appID: identity.appID,
            appName: identity.appName,
            host: identity.host,
            ruleID: rule?.id,
            basis: rule?.basis ?? automatic?.basis ?? fallbackBasis
        )
    }
}

public enum Privacy {
    public static func host(_ value: String) -> String? {
        let host = value.lowercased()
        guard host.utf8.count <= 253,
              host.range(of: #"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$"#, options: .regularExpression) != nil
        else { return nil }
        return host
    }

    public static func path(_ value: String) -> String? {
        guard value.utf8.count <= 2048, value.hasPrefix("/"),
              value.rangeOfCharacter(from: CharacterSet(charactersIn: "?#").union(.controlCharacters)) == nil
        else { return nil }
        return value
    }
}

public enum ClassificationBasis: String, Codable, Sendable {
    case app, window, domain, path, project, none
    case automaticApp, applicationCategory, automaticDomain, automaticPath, automaticWindow
    case browserDisconnected, browserPageUnavailable
    case deviceIdle, screenLocked, systemSleeping

    public var isIdle: Bool {
        self == .deviceIdle || self == .screenLocked || self == .systemSleeping
    }
}

public struct Classification: Codable, Equatable, Sendable {
    public static let deviceIdle = idle(basis: .deviceIdle)

    static func idle(basis: ClassificationBasis) -> Self {
        Classification(category: .entertainment, kind: .interactive, label: "设备空闲",
            appID: "local.workandplay.idle", appName: "设备空闲", host: nil, ruleID: nil, basis: basis)
    }

    public let category: ActivityCategory
    public let kind: ActivityKind
    public let label: String
    public let appID: String
    public let appName: String
    public let host: String?
    public let ruleID: UUID?
    public let basis: ClassificationBasis
}
