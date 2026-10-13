import Foundation
import WebKit
import OWABridgeCore

/// HTTP 请求 → WebView JS 调用的桥:
/// - 每次调用生成 correlationId,传入页面侧用于 trace / 日志对齐;
/// - 所有调用串行化(一个时刻只有一个 JS 任务在 WebView 里跑);
/// - 每个调用带超时,超时后释放队列,迟到的 JS 结果被丢弃。
@MainActor
final class JSBridge {
    struct Call {
        let correlationId: String
        let result: PageResult
        let durationMs: Int
    }

    private unowned let host: WebViewHost
    private let defaultTimeout: TimeInterval
    private var tail: Task<Void, Never>?
    private(set) var pendingCount = 0

    init(host: WebViewHost, timeout: TimeInterval) {
        self.host = host
        self.defaultTimeout = timeout
    }

    /// 调用 `window.__owaBridge.run(command, argsJSON, correlationId)`。
    func run(_ command: String, args: [String: Any] = [:], timeout: TimeInterval? = nil) async throws -> Call {
        let argsData = try JSONSerialization.data(withJSONObject: args, options: [])
        let argsJSON = String(decoding: argsData, as: UTF8.self)
        let body = """
        const b = window.__owaBridge;
        if (!b || typeof b.run !== 'function') {
          return JSON.stringify({ ok: false, status: 503, error: 'extractor_missing', message: 'extractor.js is not injected in this page' });
        }
        return await b.run(command, argsJSON, correlationId);
        """
        return try await enqueue(timeout: timeout ?? defaultTimeout) { cid in
            var raw = try await self.evaluate(body, arguments: ["command": command, "argsJSON": argsJSON, "correlationId": cid], timeout: timeout ?? self.defaultTimeout)
            var result = try PageResult.decode(raw)
            if result.error == "extractor_missing" {
                // 页面刚跳转、user script 尚未注入时补注入一次再重试。
                try await self.injectExtractor()
                raw = try await self.evaluate(body, arguments: ["command": command, "argsJSON": argsJSON, "correlationId": cid], timeout: timeout ?? self.defaultTimeout)
                result = try PageResult.decode(raw)
            }
            return result
        }
    }

    /// 执行任意函数体(用于 /debug/eval),函数体需 `return` 一个 JSON 字符串信封。
    func runBody(_ body: String, timeout: TimeInterval? = nil) async throws -> Call {
        try await enqueue(timeout: timeout ?? defaultTimeout) { cid in
            let raw = try await self.evaluate(body, arguments: ["correlationId": cid], timeout: timeout ?? self.defaultTimeout)
            return try PageResult.decode(raw)
        }
    }

    // MARK: - 串行队列

    private func enqueue(timeout: TimeInterval, _ work: @escaping (String) async throws -> PageResult) async throws -> Call {
        let cid = UUID().uuidString.lowercased()
        let previous = tail
        pendingCount += 1
        let task = Task { @MainActor () -> Result<Call, Error> in
            await previous?.value
            let started = Date()
            do {
                let result = try await work(cid)
                return .success(Call(correlationId: cid, result: result, durationMs: Int(Date().timeIntervalSince(started) * 1000)))
            } catch {
                return .failure(error)
            }
        }
        tail = Task { _ = await task.value }
        defer { pendingCount -= 1 }
        return try await task.value.get()
    }

    // MARK: - WebKit

    private final class Once {
        var done = false
    }

    private func evaluate(_ body: String, arguments: [String: Any], timeout: TimeInterval) async throws -> String {
        let webView = host.webView
        let world = host.contentWorld
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let once = Once()
            let finish: (Result<String, Error>) -> Void = { result in
                guard !once.done else { return }
                once.done = true
                cont.resume(with: result)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(APIError.timeout("WebView did not respond within \(Int(timeout))s")))
            }
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
                switch result {
                case .success(let value):
                    if let s = value as? String {
                        finish(.success(s))
                    } else {
                        finish(.failure(APIError.extractFailed("page returned \(type(of: value)) instead of a JSON string")))
                    }
                case .failure(let error):
                    finish(.failure(JSBridgeError.javaScript(Self.describe(error))))
                }
            }
        }
    }

    private func injectExtractor() async throws {
        let webView = host.webView
        let world = host.contentWorld
        let source = host.extractorSource
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            webView.evaluateJavaScript(source, in: nil, in: world) { result in
                switch result {
                case .success: cont.resume()
                case .failure(let error): cont.resume(throwing: JSBridgeError.javaScript(Self.describe(error)))
                }
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if let message = ns.userInfo["WKJavaScriptExceptionMessage"] as? String {
            return message
        }
        return ns.localizedDescription
    }
}

enum JSBridgeError: Error {
    case javaScript(String)
}
