import Foundation

public struct HTTPRequest {
    public let method: String
    /// 原始 request-target,如 `/messages?top=5`。
    public let target: String
    /// 原始(未解码)路径,如 `/messages/AAMk%2Fx`。
    public let path: String
    /// 解码后的 query 参数(同名取最后一个)。
    public let query: [String: String]
    /// header 名称统一小写。
    public let headers: [String: String]
    public let body: Data

    public init(method: String, target: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.target = target
        let (path, query) = HTTPRequest.splitTarget(target)
        self.path = path
        self.query = query
        var lowered: [String: String] = [:]
        for (k, v) in headers { lowered[k.lowercased()] = v }
        self.headers = lowered
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    static func splitTarget(_ target: String) -> (String, [String: String]) {
        // 允许 absolute-form(http://host/path),只取路径部分。
        var t = Substring(target)
        if let schemeRange = t.range(of: "://") {
            let afterScheme = t[schemeRange.upperBound...]
            if let slash = afterScheme.firstIndex(of: "/") {
                t = afterScheme[slash...]
            } else {
                t = "/"
            }
        }
        if let hash = t.firstIndex(of: "#") { t = t[..<hash] }
        guard let q = t.firstIndex(of: "?") else {
            return (t.isEmpty ? "/" : String(t), [:])
        }
        let path = String(t[..<q])
        let queryString = t[t.index(after: q)...]
        return (path.isEmpty ? "/" : path, parseQuery(queryString))
    }

    public static func parseQuery<S: StringProtocol>(_ s: S) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = decodeComponent(parts[0])
            guard !key.isEmpty else { continue }
            out[key] = parts.count > 1 ? decodeComponent(parts[1]) : ""
        }
        return out
    }

    static func decodeComponent<S: StringProtocol>(_ s: S) -> String {
        let plusDecoded = s.replacingOccurrences(of: "+", with: " ")
        return plusDecoded.removingPercentEncoding ?? plusDecoded
    }
}

public enum HTTPParseResult {
    case incomplete
    case complete(HTTPRequest)
    case invalid(String)
}

/// 极简 HTTP/1.1 请求解析:只支持 Content-Length 请求体,不支持 chunked。
public enum HTTPRequestParser {
    public static let maxHeaderBytes = 64 * 1024
    public static let maxBodyBytes = 1 << 20

    private static let crlfcrlf: [UInt8] = [13, 10, 13, 10]

    public static func parse(_ data: Data) -> HTTPParseResult {
        let bytes = [UInt8](data)
        guard let headerEnd = find(crlfcrlf, in: bytes) else {
            return bytes.count > maxHeaderBytes ? .invalid("header too large") : .incomplete
        }
        if headerEnd > maxHeaderBytes { return .invalid("header too large") }
        guard let head = String(bytes: bytes[0..<headerEnd], encoding: .utf8)
            ?? String(bytes: bytes[0..<headerEnd], encoding: .isoLatin1) else {
            return .invalid("undecodable header")
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .invalid("malformed request line")
        }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        guard method.allSatisfy({ $0.isLetter }), target.hasPrefix("/") || target.contains("://") else {
            return .invalid("malformed request line")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("malformed header") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid("malformed header") }
            headers[name] = value
        }

        if let te = headers["transfer-encoding"], te.lowercased() != "identity" {
            return .invalid("transfer-encoding not supported")
        }
        var contentLength = 0
        if let cl = headers["content-length"] {
            guard let n = Int(cl), n >= 0 else { return .invalid("bad content-length") }
            contentLength = n
        }
        if contentLength > maxBodyBytes { return .invalid("body too large") }

        let bodyStart = headerEnd + crlfcrlf.count
        guard bytes.count - bodyStart >= contentLength else { return .incomplete }
        let body = Data(bytes[bodyStart..<(bodyStart + contentLength)])
        return .complete(HTTPRequest(method: method, target: target, headers: headers, body: body))
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        var i = 0
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == needle[0] {
                var match = true
                for j in 1..<needle.count where haystack[i + j] != needle[j] {
                    match = false
                    break
                }
                if match { return i }
            }
            i += 1
        }
        return nil
    }
}
