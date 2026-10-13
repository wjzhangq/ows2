import Foundation
import Network
import OWABridgeCore

/// 基于 Network.framework 的极简 HTTP 服务器,只绑定 127.0.0.1。
/// 每个连接处理一个请求后关闭(Connection: close)。
final class HTTPServer {
    typealias Handler = (HTTPRequest) async -> HTTPResponse

    private let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "owa-bridge.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    var onStateChange: ((String) -> Void)?

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw APIError.internal("invalid port \(port)")
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.info("http.listening", ["address": "127.0.0.1:\(self.port)"])
                self.onStateChange?("listening")
            case .failed(let error):
                Log.error("http.listen_failed", ["port": Int(self.port), "error": "\(error)"])
                self.onStateChange?("failed: \(error)")
            case .cancelled:
                self.onStateChange?("stopped")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] nwConnection in
            self?.accept(nwConnection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async {
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    /// 在 `queue` 上调用。
    private func accept(_ nwConnection: NWConnection) {
        let connection = HTTPConnection(connection: nwConnection, queue: queue, handler: handler)
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.onClose = { [weak self] in
            self?.queue.async { self?.connections.removeValue(forKey: id) }
        }
        connection.start()
    }
}

private final class HTTPConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPServer.Handler
    private var buffer = Data()
    private var closed = false
    private var idleTimer: DispatchWorkItem?
    var onClose: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping HTTPServer.Handler) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        // 读请求阶段 15s 未完成则断开,防止半开连接堆积。
        let timer = DispatchWorkItem { [weak self] in self?.cancel() }
        idleTimer = timer
        queue.asyncAfter(deadline: .now() + 15, execute: timer)
        receive()
    }

    func cancel() {
        connection.cancel()
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        idleTimer?.cancel()
        onClose?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            switch HTTPRequestParser.parse(self.buffer) {
            case .complete(let request):
                self.idleTimer?.cancel()
                self.dispatch(request)
            case .invalid(let reason):
                self.idleTimer?.cancel()
                self.send(.error(.badRequest(reason)))
            case .incomplete:
                if isComplete || error != nil {
                    self.cancel()
                } else {
                    self.receive()
                }
            }
        }
    }

    private func dispatch(_ request: HTTPRequest) {
        let handler = self.handler
        let started = Date()
        Task {
            var response = await handler(request)
            if request.method == "HEAD" { response.body = Data() }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Log.info("http.request", ["method": request.method, "path": request.path, "status": response.status, "ms": ms])
            let finalResponse = response
            self.queue.async { self.send(finalResponse) }
        }
    }

    private func send(_ response: HTTPResponse) {
        connection.send(content: response.serialize(), completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
    }
}
