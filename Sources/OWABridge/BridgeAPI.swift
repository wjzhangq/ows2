import Foundation
import OWABridgeCore

/// HTTP 接口层:鉴权 + 路由 + 把请求转成页面侧抽取命令。
@MainActor
final class BridgeAPI {
    struct ExtractionRecord {
        let target: String
        let provider: String?
        let durationMs: Int
        let ok: Bool
        let error: String?
        let at: Date
        let correlationId: String?
    }

    private let router = Router()
    private let token: String
    let config: BridgeConfig
    let host: WebViewHost
    let bridge: JSBridge
    private let startedAt = Date()
    private(set) var lastExtraction: ExtractionRecord?
    private var lastProvider: String?

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 不需要 token 的路径(只返回存活信息)。
    private let publicPaths: Set<String> = ["/healthz"]

    init(config: BridgeConfig, token: String, host: WebViewHost, bridge: JSBridge) {
        self.config = config
        self.token = token
        self.host = host
        self.bridge = bridge
        registerRoutes()
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if !publicPaths.contains(request.path),
           !BearerAuth.isAuthorized(header: request.header("authorization"), token: token) {
            return .error(.unauthorized())
        }
        switch router.match(method: request.method, path: request.path) {
        case .found(let handler, let params):
            return await handler(request, params)
        case .methodNotAllowed(let allowed):
            var resp = HTTPResponse.error(.methodNotAllowed())
            resp.headers.append(("Allow", allowed.joined(separator: ", ")))
            return resp
        case .notFound:
            return .error(.notFound("no route for \(request.method) \(request.path)"))
        }
    }

    // MARK: - 路由

    private func registerRoutes() {
        router.add("GET", "/healthz") { _, _ in .json(200, ["ok": true]) }
        router.add("GET", "/status") { [unowned self] _, _ in await self.status() }

        router.add("GET", "/me") { [unowned self] req, _ in
            await self.extract(target: "me", command: "me", args: ["debug": req.boolQuery("debug")], debug: req.boolQuery("debug"), extraOnError: ["loggedIn": false])
        }

        router.add("GET", "/messages") { [unowned self] req, _ in
            switch MessagesQuery.parse(req) {
            case .failure(let e): return .error(e)
            case .success(let q): return await self.extract(target: "messages", command: "messages", args: q.jsArgs, debug: q.debug)
            }
        }

        router.add("GET", "/messages/*id") { [unowned self] req, params in
            switch MessageQuery.parse(id: params["id"], req) {
            case .failure(let e): return .error(e)
            case .success(let q): return await self.extract(target: "message", command: "message", args: q.jsArgs, debug: q.debug)
            }
        }

        registerDebugRoutes()
    }

    /// 由 debug 扩展填充(见 BridgeAPI+Debug.swift)。
    private func registerDebugRoutes() {
        registerDebugEndpoints(on: router)
    }

    // MARK: - 会话门禁

    /// 数据端点在明确未登录时直接返回 401,不去页面里白跑一趟。
    func sessionGate() -> APIError? {
        switch host.state {
        case .notLoggedIn:
            return .notLoggedIn()
        case .expired:
            return .sessionExpired()
        case .loading:
            if !SessionClassifier.isOWAHost(host.currentURL?.host) {
                return .notLoggedIn("OWA is still loading or waiting for sign-in")
            }
            return nil
        case .loggedIn:
            return nil
        }
    }

    // MARK: - 抽取

    func extract(target: String, command: String, args: [String: Any], debug: Bool, extraOnError: [String: Any] = [:]) async -> HTTPResponse {
        if let gate = sessionGate() {
            return .error(gate, extra: extraOnError)
        }
        let started = Date()
        do {
            let call = try await bridge.run(command, args: args)
            let r = call.result
            record(target: target, provider: r.provider, started: started, ok: r.ok, error: r.error, cid: call.correlationId)
            var debugBlock: [String: Any]?
            if debug {
                var d = r.debug ?? [:]
                d["correlationId"] = call.correlationId
                d["bridgeMs"] = Int(Date().timeIntervalSince(started) * 1000)
                d["pageMs"] = call.durationMs
                debugBlock = d
            }
            if let apiError = r.apiError {
                if apiError.code == "session_expired" { host.reportAuthFailure() }
                var extra = extraOnError
                if let debugBlock { extra["_debug"] = debugBlock }
                return .error(apiError, extra: extra)
            }
            if r.provider != nil { lastProvider = r.provider }
            guard var body = r.data as? [String: Any] else {
                return .error(.extractFailed("page returned no data"))
            }
            if let debugBlock { body["_debug"] = debugBlock }
            return .json(200, body)
        } catch {
            let apiError = Self.apiError(from: error)
            record(target: target, provider: nil, started: started, ok: false, error: apiError.code, cid: nil)
            return .error(apiError, extra: extraOnError)
        }
    }

    private func orNull(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    static func apiError(from error: Error) -> APIError {
        if let e = error as? APIError { return e }
        if case JSBridgeError.javaScript(let message) = error { return .extractFailed("JavaScript error: \(message)") }
        return .internal(String(describing: error))
    }

    private func record(target: String, provider: String?, started: Date, ok: Bool, error: String?, cid: String?) {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        lastExtraction = ExtractionRecord(target: target, provider: provider, durationMs: ms, ok: ok, error: error, at: Date(), correlationId: cid)
        // 结构化日志:只记元数据,不记邮件内容。
        Log.info("extract", ["target": target, "provider": provider ?? "", "ms": ms, "ok": ok, "error": error ?? "", "cid": cid ?? ""])
    }

    // MARK: - /status

    private func status() async -> HTTPResponse {
        var body: [String: Any] = [
            "ok": true,
            "version": BridgeVersion.current,
            "sessionState": host.state.rawValue,
            "loggedIn": host.state.isLoggedIn,
            "provider": orNull(lastProvider),
            "url": orNull(host.currentURL?.absoluteString),
            "windowVisible": host.isPresented,
            "port": Int(config.port),
            "uptimeSeconds": Int(Date().timeIntervalSince(startedAt)),
            "pendingRequests": bridge.pendingCount,
            "debugEvalEnabled": config.enableDebugEval,
            "scriptWorld": config.scriptWorld.rawValue,
        ]
        if let e = lastExtraction {
            body["lastExtraction"] = [
                "target": e.target,
                "provider": orNull(e.provider),
                "durationMs": e.durationMs,
                "ok": e.ok,
                "error": orNull(e.error),
                "at": isoFormatter.string(from: e.at),
                "correlationId": orNull(e.correlationId),
            ] as [String: Any]
        } else {
            body["lastExtraction"] = NSNull()
        }
        // 页面侧状态(provider 是否被暂停等);拿不到不影响 /status。
        if SessionClassifier.isOWAHost(host.currentURL?.host),
           let call = try? await bridge.run("status", timeout: 3),
           call.result.ok, let page = call.result.data {
            body["page"] = page
        }
        return .json(200, body)
    }
}
