import Foundation

public struct HTTPResponse {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        let data: Data
        if JSONSerialization.isValidJSONObject(object),
           let d = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) {
            data = d
        } else {
            data = Data(#"{"error":"internal","message":"response encoding failed"}"#.utf8)
            return jsonData(500, data)
        }
        return jsonData(status, data)
    }

    public static func jsonData(_ status: Int, _ data: Data) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: data)
    }

    public static func error(_ error: APIError, extra: [String: Any] = [:]) -> HTTPResponse {
        var obj: [String: Any] = extra
        obj["error"] = error.code
        obj["message"] = error.message
        return json(error.status, obj)
    }

    public func serialize() -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        var hasContentType = false
        for (k, v) in headers {
            if k.lowercased() == "content-length" || k.lowercased() == "connection" { continue }
            if k.lowercased() == "content-type" { hasContentType = true }
            head += "\(k): \(v)\r\n"
        }
        if !hasContentType && !body.isEmpty {
            head += "Content-Type: application/octet-stream\r\n"
        }
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Status"
        }
    }
}
