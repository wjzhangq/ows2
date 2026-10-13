import Foundation

/// 极简路由:支持字面量段、`:name` 单段参数、`*name` 吞掉剩余路径(用于含 `/` 的邮件 id)。
public final class Router {
    public typealias Handler = (HTTPRequest, [String: String]) async -> HTTPResponse

    enum Segment: Equatable {
        case literal(String)
        case param(String)
        case rest(String)
    }

    struct Route {
        let method: String
        let segments: [Segment]
        let handler: Handler
    }

    public enum Match {
        case found(Handler, [String: String])
        case methodNotAllowed([String])
        case notFound
    }

    private var routes: [Route] = []

    public init() {}

    public func add(_ method: String, _ pattern: String, _ handler: @escaping Handler) {
        let segments: [Segment] = pattern.split(separator: "/").map { s in
            if s.hasPrefix(":") { return .param(String(s.dropFirst())) }
            if s.hasPrefix("*") { return .rest(String(s.dropFirst())) }
            return .literal(String(s))
        }
        routes.append(Route(method: method.uppercased(), segments: segments, handler: handler))
    }

    public func match(method: String, path: String) -> Match {
        let raw = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var allowed: [String] = []
        for route in routes {
            guard let params = Router.bind(route.segments, raw) else { continue }
            if route.method == method.uppercased() || (method.uppercased() == "HEAD" && route.method == "GET") {
                return .found(route.handler, params)
            }
            allowed.append(route.method)
        }
        return allowed.isEmpty ? .notFound : .methodNotAllowed(allowed)
    }

    static func bind(_ segments: [Segment], _ raw: [String]) -> [String: String]? {
        var params: [String: String] = [:]
        var i = 0
        for (idx, seg) in segments.enumerated() {
            switch seg {
            case .literal(let lit):
                guard i < raw.count, decode(raw[i]) == lit else { return nil }
                i += 1
            case .param(let name):
                guard i < raw.count else { return nil }
                params[name] = decode(raw[i])
                i += 1
            case .rest(let name):
                guard idx == segments.count - 1, i < raw.count else { return nil }
                params[name] = raw[i...].map(decode).joined(separator: "/")
                i = raw.count
            }
        }
        return i == raw.count ? params : nil
    }

    static func decode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }
}

public extension HTTPRequest {
    func boolQuery(_ name: String, default def: Bool = false) -> Bool {
        guard let v = query[name]?.lowercased() else { return def }
        switch v {
        case "", "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return def
        }
    }
}
