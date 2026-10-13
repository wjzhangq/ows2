import Foundation

/// 对外错误体 `{ "error": code, "message": ... }`。
public struct APIError: Error, Equatable {
    public let status: Int
    public let code: String
    public let message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    public static func unauthorized(_ m: String = "missing or invalid bearer token") -> APIError { .init(status: 403, code: "unauthorized", message: m) }
    public static func sessionExpired(_ m: String = "OWA session expired; please sign in again") -> APIError { .init(status: 401, code: "session_expired", message: m) }
    public static func notLoggedIn(_ m: String = "not signed in to OWA; sign in via the menu bar window") -> APIError { .init(status: 401, code: "not_logged_in", message: m) }
    public static func extractFailed(_ m: String) -> APIError { .init(status: 502, code: "extract_failed", message: m) }
    public static func timeout(_ m: String = "WebView did not respond in time") -> APIError { .init(status: 504, code: "timeout", message: m) }
    public static func notFound(_ m: String = "not found") -> APIError { .init(status: 404, code: "not_found", message: m) }
    public static func badRequest(_ m: String) -> APIError { .init(status: 400, code: "bad_request", message: m) }
    public static func methodNotAllowed(_ m: String = "method not allowed") -> APIError { .init(status: 405, code: "method_not_allowed", message: m) }
    public static func debugEvalDisabled() -> APIError { .init(status: 403, code: "debug_eval_disabled", message: "set \"enableDebugEval\": true in ~/.owa-bridge/config.json and restart to enable /debug/eval") }
    public static func `internal`(_ m: String) -> APIError { .init(status: 500, code: "internal", message: m) }

    /// 把页面侧返回的错误码映射成 HTTP 状态。
    public static func fromPage(code: String, message: String, status: Int?) -> APIError {
        let mapped: Int
        switch code {
        case "session_expired", "not_logged_in": mapped = 401
        case "not_found": mapped = 404
        case "bad_request": mapped = 400
        case "timeout": mapped = 504
        case "extract_failed": mapped = 502
        default: mapped = status ?? 502
        }
        return APIError(status: mapped, code: code, message: message)
    }
}
