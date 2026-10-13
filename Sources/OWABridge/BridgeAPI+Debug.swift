import Foundation
import OWABridgeCore

/// `/debug/*`:把页面真实形态结构化地交给 AI 分析(均需本地 token)。
/// 这些端点不经过会话门禁——登录页本身也常常需要分析。
extension BridgeAPI {
    func registerDebugEndpoints(on router: Router) {
        router.add("GET", "/debug/dom") { [unowned self] req, _ in
            var args: [String: Any] = [:]
            if let s = req.query["selector"], !s.isEmpty { args["selector"] = s }
            if let n = req.query["maxLength"].flatMap(Int.init) { args["maxLength"] = n }
            return await self.pageCommand("dom", args: args)
        }

        router.add("GET", "/debug/aria") { [unowned self] req, _ in
            var args: [String: Any] = ["includeText": req.boolQuery("includeText", default: true)]
            if let s = req.query["selector"], !s.isEmpty { args["selector"] = s }
            if let n = req.query["maxDepth"].flatMap(Int.init) { args["maxDepth"] = n }
            if let n = req.query["maxNodes"].flatMap(Int.init) { args["maxNodes"] = n }
            return await self.pageCommand("aria", args: args)
        }

        router.add("GET", "/debug/snapshot") { [unowned self] req, _ in
            await self.snapshot(raw: req.query["format"]?.lowercased() == "png")
        }

        router.add("GET", "/debug/extract") { [unowned self] req, _ in
            let target = req.query["target"] ?? "messages"
            var args: [String: Any] = ["target": target]
            switch target {
            case "messages":
                switch MessagesQuery.parse(req) {
                case .failure(let e): return .error(e)
                case .success(let q): args.merge(q.jsArgs) { current, _ in current }
                }
            case "message":
                switch MessageQuery.parse(id: req.query["id"], req) {
                case .failure(let e): return .error(e)
                case .success(let q): args.merge(q.jsArgs) { current, _ in current }
                }
            case "me":
                break
            default:
                return .error(.badRequest("target must be messages, message or me"))
            }
            return await self.pageCommand("extract", args: args)
        }

        let evalHandler: Router.Handler = { [unowned self] req, _ in
            await self.debugEval(req)
        }
        router.add("GET", "/debug/eval", evalHandler)
        router.add("POST", "/debug/eval", evalHandler)
    }

    /// 执行页面侧命令并原样返回其 data(附 correlationId)。
    func pageCommand(_ command: String, args: [String: Any]) async -> HTTPResponse {
        do {
            let call = try await bridge.run(command, args: args)
            if let e = call.result.apiError { return .error(e) }
            guard var body = call.result.data as? [String: Any] else {
                return .error(.extractFailed("page returned no data"))
            }
            body["correlationId"] = call.correlationId
            return .json(200, body)
        } catch {
            return .error(Self.apiError(from: error))
        }
    }

    private func snapshot(raw: Bool) async -> HTTPResponse {
        do {
            let (png, width, height) = try await host.snapshotPNG()
            if raw {
                return HTTPResponse(status: 200, headers: [("Content-Type", "image/png")], body: png)
            }
            return .json(200, [
                "contentType": "image/png",
                "width": width,
                "height": height,
                "url": host.currentURL?.absoluteString ?? "",
                "base64": png.base64EncodedString(),
            ] as [String: Any])
        } catch {
            return .error(Self.apiError(from: error))
        }
    }

    /// `/debug/eval`:默认关闭。代码作为 async 函数体执行;单个表达式会自动加 `return`。
    /// 代码来源:`?code=` 或 POST 请求体(text/plain)。
    private func debugEval(_ req: HTTPRequest) async -> HTTPResponse {
        guard config.enableDebugEval else { return .error(.debugEvalDisabled()) }
        var code = req.query["code"] ?? ""
        if req.method == "POST", !req.body.isEmpty {
            code = String(decoding: req.body, as: UTF8.self)
        }
        code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return .error(.badRequest("provide JavaScript via ?code= or the POST body")) }

        let body = """
        const __serialize = (v) => (window.__owaBridge && window.__owaBridge.serialize) ? window.__owaBridge.serialize(v) : (v === undefined ? null : v);
        try {
          const __result = await (async () => {
        \(DebugEval.functionBody(for: code))
          })();
          return JSON.stringify({ ok: true, status: 200, data: { result: __serialize(__result) } });
        } catch (e) {
          return JSON.stringify({ ok: false, status: 400, error: 'eval_error', message: String(e && e.stack || e) });
        }
        """
        Log.warn("debug.eval", ["bytes": code.utf8.count])
        do {
            let call = try await bridge.runBody(body)
            if let e = call.result.apiError { return .error(e) }
            var out = (call.result.data as? [String: Any]) ?? [:]
            out["correlationId"] = call.correlationId
            return .json(200, out)
        } catch JSBridgeError.javaScript(let message) {
            return .error(APIError(status: 400, code: "eval_error", message: message))
        } catch {
            return .error(Self.apiError(from: error))
        }
    }
}
