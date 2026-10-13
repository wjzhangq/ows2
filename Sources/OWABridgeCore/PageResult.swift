import Foundation

/// 页面侧 `__owaBridge.run()` 返回的 JSON 信封:
/// `{ ok, status, provider, data, debug }` 或 `{ ok:false, status, error, message, debug }`。
public struct PageResult {
    public let ok: Bool
    public let status: Int?
    public let provider: String?
    public let data: Any?
    public let debug: [String: Any]?
    public let error: String?
    public let message: String?

    public static func decode(_ json: String) throws -> PageResult {
        guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? [String: Any] else {
            throw APIError.extractFailed("page returned a non-object result")
        }
        return PageResult(
            ok: obj["ok"] as? Bool ?? false,
            status: obj["status"] as? Int,
            provider: obj["provider"] as? String,
            data: obj["data"].flatMap { $0 is NSNull ? nil : $0 },
            debug: obj["debug"] as? [String: Any],
            error: obj["error"] as? String,
            message: obj["message"] as? String
        )
    }

    public var apiError: APIError? {
        guard !ok else { return nil }
        return APIError.fromPage(code: error ?? "extract_failed", message: message ?? "extraction failed", status: status)
    }
}
