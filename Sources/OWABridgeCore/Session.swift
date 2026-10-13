import Foundation

public enum SessionState: String, Equatable {
    /// 启动中 / 页面加载中,尚未判定。
    case loading
    /// 已登录,邮件界面可用。
    case loggedIn
    /// 从未登录(停在登录页)。
    case notLoggedIn
    /// 曾经登录,后来失效(跳回登录页或接口 401)。
    case expired

    public var isLoggedIn: Bool { self == .loggedIn }

    /// 需要人工登录(应弹出窗口)。
    public var needsLogin: Bool { self == .notLoggedIn || self == .expired }

    public var displayText: String {
        switch self {
        case .loading: return "加载中…"
        case .loggedIn: return "已登录"
        case .notLoggedIn: return "未登录"
        case .expired: return "会话已失效,请重新登录"
        }
    }
}

/// 一次观测到的页面状况。
public enum SessionObservation: Equatable {
    /// 当前位于登录/身份提供方页面。
    case loginPage
    /// 位于 OWA 域名,但邮件界面尚未就绪。
    case owaLoading
    /// OWA 邮件界面已就绪。
    case mailReady
    /// 抽取时页面侧判定会话失效。
    case authFailed
}

public enum SessionMachine {
    public static func next(_ current: SessionState, _ observation: SessionObservation) -> SessionState {
        switch observation {
        case .mailReady:
            return .loggedIn
        case .loginPage, .authFailed:
            return (current == .loggedIn || current == .expired) ? .expired : .notLoggedIn
        case .owaLoading:
            return current
        }
    }
}

/// 根据 URL host 判断页面类型。
public enum SessionClassifier {
    public static let owaHosts: Set<String> = [
        "outlook.office.com",
        "outlook.office365.com",
        "outlook.cloud.microsoft",
        "outlook.live.com",
    ]

    public static func isOWAHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return owaHosts.contains(host)
    }

    /// 非 OWA 的 http(s) 页面一律视为登录/身份提供方页面(含 AAD、MSA 与企业 ADFS/Okta 等联合登录)。
    public static func observe(url: URL?) -> SessionObservation? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return isOWAHost(url.host) ? .owaLoading : .loginPage
    }
}
