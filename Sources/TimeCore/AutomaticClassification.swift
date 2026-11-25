import Foundation

enum AutomaticClassification {
    struct Match {
        let category: ActivityCategory
        let kind: ActivityKind
        let basis: ClassificationBasis
    }

    private static let workApps: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "com.microsoft.vscode", "com.apple.dt.xcode",
        "com.todesktop.230313mzl4w4u92", "dev.kiro.desktop", "cn.trae.app", "cn.trae.solo.app",
        "com.workbuddy.workbuddy", "com.navicat.navicatformysql", "com.postmanlabs.mac",
        "com.openai.codex", "com.openai.chat", "com.openai.chatgpt",
        "com.docker.docker", "com.github.github", "com.microsoft.powershell",
        "com.apple.iwork.pages", "com.apple.iwork.numbers", "com.apple.iwork.keynote",
        "com.microsoft.word", "com.microsoft.excel", "com.microsoft.powerpoint",
        "com.kingsoft.wpsoffice.mac", "com.figma.desktop", "com.typora.mac", "abnerworks.typora",
        "com.apple.mail", "com.netease.macmail", "com.microsoft.outlook",
        "com.tinyspeck.slackmacgap", "com.electron.lark", "com.tencent.weworkmac", "com.tencent.meeting"
    ]
    private static let entertainmentApps: Set<String> = [
        "com.apple.music", "com.apple.tv", "com.apple.podcasts", "com.spotify.client",
        "com.netease.163music", "com.apple.quicktimeplayerx", "org.videolan.vlc",
        "com.colliderli.iina", "com.valvesoftware.steam", "com.epicgames.epicgameslauncher",
        "org.openemu.openemu", "com.mojang.minecraftlauncher"
    ]
    private static let workDomains = [
        "github.com", "gitlab.com", "bitbucket.org", "atlassian.net", "figma.com", "linear.app",
        "chatgpt.com", "chat.openai.com",
        "docs.google.com", "drive.google.com", "mail.google.com", "calendar.google.com",
        "office.com", "microsoft365.com", "sharepoint.com", "open.feishu.cn", "larksuite.com", "kdocs.cn",
        "console.aws.amazon.com", "console.cloud.google.com", "portal.azure.com", "console.volcengine.com"
    ]
    private static let readingDomains = [
        "developer.apple.com", "developer.mozilla.org", "learn.microsoft.com", "developers.openai.com",
        "docs.github.com", "docs.python.org", "devdocs.io", "stackoverflow.com"
    ]
    private static let entertainmentDomains = [
        "youtube.com", "youtu.be", "netflix.com", "disneyplus.com", "bilibili.com", "iqiyi.com",
        "v.qq.com", "youku.com", "douyin.com", "twitch.tv", "open.spotify.com", "music.apple.com",
        "tv.apple.com", "music.163.com", "steampowered.com"
    ]

    static func match(_ identity: ActivityIdentity) -> Match? {
        if let host = identity.host.flatMap(Privacy.host) {
            if host == "studio.youtube.com" ||
                ((host == "www.youtube.com" || host == "youtube.com") && identity.path == "/upload") {
                return Match(category: .work, kind: .interactive, basis: .automaticPath)
            }
            if contains(host, in: readingDomains) {
                return Match(category: .work, kind: .reading, basis: .automaticDomain)
            }
            if contains(host, in: workDomains) {
                return Match(category: .work, kind: .interactive, basis: .automaticDomain)
            }
            if (host == "www.youtube.com" || host == "youtube.com") && identity.path == nil { return nil }
            if contains(host, in: entertainmentDomains) {
                return Match(category: .entertainment, kind: .interactive, basis: .automaticDomain)
            }
            return nil
        }

        let app = identity.appID.lowercased()
        if app == "com.tencent.xinwechat" {
            // Match known view captions, not arbitrary chat names containing a keyword.
            let title = identity.window?.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["朋友圈", "视频号", "微信小游戏"].contains(where: { title == $0 }) {
                return Match(category: .entertainment, kind: .interactive, basis: .automaticWindow)
            }
            return nil
        }
        if workApps.contains(app) { return Match(category: .work, kind: .interactive, basis: .automaticApp) }
        if entertainmentApps.contains(app) { return Match(category: .entertainment, kind: .interactive, basis: .automaticApp) }

        switch identity.appCategory?.lowercased() {
        case "public.app-category.developer-tools":
            return Match(category: .work, kind: .interactive, basis: .applicationCategory)
        case "public.app-category.entertainment", "public.app-category.games":
            return Match(category: .entertainment, kind: .interactive, basis: .applicationCategory)
        case let category? where category.hasPrefix("public.app-category.") && category.hasSuffix("-games"):
            return Match(category: .entertainment, kind: .interactive, basis: .applicationCategory)
        default:
            return nil
        }
    }

    private static func contains(_ host: String, in domains: [String]) -> Bool {
        domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
