import Foundation
import OWABridgeCore

/// HTTP 接口层:鉴权 + 路由。
@MainActor
final class BridgeAPI {
    private let router = Router()
    private let token: String
    private let config: BridgeConfig
    private let startedAt = Date()

    /// 不需要 token 的路径(只返回存活信息)。
    private let publicPaths: Set<String> = ["/healthz"]

    init(config: BridgeConfig, token: String) {
        self.config = config
        self.token = token
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

    private func registerRoutes() {
        router.add("GET", "/healthz") { _, _ in .json(200, ["ok": true]) }
    }
}
