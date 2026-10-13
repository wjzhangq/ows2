import AppKit
import WebKit
import OWABridgeCore

/// 允许被移出屏幕的窗口(默认 NSWindow 会把标题栏窗口约束回可见区域)。
final class BridgeWindow: NSWindow {
    var allowOffscreen = true

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowOffscreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// 避免 WKUserContentController 强引用 handler 造成循环。
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// 持有常驻的 WKWebView:持久会话、离屏保活、登录态检测、窗口显示/隐藏。
@MainActor
final class WebViewHost: NSObject {
    static let messageHandlerName = "owaBridge"

    let webView: WKWebView
    let window: BridgeWindow
    let contentWorld: WKContentWorld
    let extractorSource: String

    private let config: BridgeConfig
    private let startURL: URL
    private(set) var state: SessionState = .loading
    private(set) var isPresented = false
    private var autoShownForLogin = false
    private var probeTask: Task<Void, Never>?
    private var stateObservers: [(SessionState) -> Void] = []

    /// 由 AppDelegate 注入,用于在页面里执行 probe。
    var prober: (() async -> SessionObservation?)?

    private static let visibleSize = NSSize(width: 1100, height: 800)
    private static let offscreenOrigin = NSPoint(x: -30000, y: -30000)

    init(config: BridgeConfig, extractorSource: String) {
        self.config = config
        self.extractorSource = extractorSource
        self.startURL = URL(string: config.startURL) ?? URL(string: BridgeConfig.default.startURL)!
        self.contentWorld = config.scriptWorld == .page ? .page : .defaultClient

        let wkConfig = WKWebViewConfiguration()
        // 默认持久化 data store:cookie / localStorage / IndexedDB 落盘,重启免登。
        wkConfig.websiteDataStore = .default()
        wkConfig.applicationNameForUserAgent = config.applicationNameForUserAgent
        if #available(macOS 14.0, *) {
            // 窗口不可见时也不要挂起页面里的 JS / 定时器。
            wkConfig.preferences.inactiveSchedulingPolicy = .none
        }

        let userScript = WKUserScript(
            source: extractorSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: contentWorld
        )
        wkConfig.userContentController.addUserScript(userScript)

        webView = WKWebView(frame: NSRect(origin: .zero, size: Self.visibleSize), configuration: wkConfig)
        webView.allowsBackForwardNavigationGestures = false

        window = BridgeWindow(
            contentRect: NSRect(origin: Self.offscreenOrigin, size: Self.visibleSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        wkConfig.userContentController.add(WeakScriptMessageHandler(self), contentWorld: contentWorld, name: Self.messageHandlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        window.title = "OWA Bridge — Outlook"
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
        window.isExcludedFromWindowsMenu = true
        hideWindow()
    }

    // MARK: - 生命周期

    func start() {
        Log.info("webview.load", ["url": startURL.absoluteString])
        webView.load(URLRequest(url: startURL))
        let interval = UInt64(config.probeIntervalSeconds * 1_000_000_000)
        probeTask?.cancel()
        probeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                await self?.probe()
            }
        }
    }

    func reload() {
        if let url = webView.url, SessionClassifier.isOWAHost(url.host) {
            webView.reload()
        } else {
            webView.load(URLRequest(url: startURL))
        }
    }

    var currentURL: URL? { webView.url }

    // MARK: - 状态

    func observeState(_ observer: @escaping (SessionState) -> Void) {
        stateObservers.append(observer)
        observer(state)
    }

    func apply(_ observation: SessionObservation) {
        let next = SessionMachine.next(state, observation)
        guard next != state else { return }
        let previous = state
        state = next
        Log.info("session.state", ["from": previous.rawValue, "to": next.rawValue, "host": webView.url?.host ?? ""])
        stateObservers.forEach { $0(next) }

        if next.needsLogin, config.autoShowLoginWindow, !isPresented {
            autoShownForLogin = true
            showWindow()
        } else if next.isLoggedIn, autoShownForLogin {
            // 登录完成后自动收回菜单栏。
            autoShownForLogin = false
            hideWindow()
        }
    }

    /// 抽取时页面侧报告会话失效:更新状态并刷新,让 OWA 跳转到登录页。
    func reportAuthFailure() {
        apply(.authFailed)
        reload()
    }

    func probe() async {
        guard let observation = SessionClassifier.observe(url: webView.url) else { return }
        if observation == .loginPage {
            apply(.loginPage)
            return
        }
        if let prober, let result = await prober() {
            apply(result)
        }
    }

    // MARK: - 窗口

    func showWindow() {
        isPresented = true
        window.allowOffscreen = false
        window.collectionBehavior = []
        window.ignoresMouseEvents = false
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(Self.visibleSize.width, screenFrame.width), height: min(Self.visibleSize.height, screenFrame.height))
        let origin = NSPoint(x: screenFrame.midX - size.width / 2, y: screenFrame.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// "隐藏" = 移到屏幕外但保持在窗口层级中,WebView 继续渲染并执行 JS。
    func hideWindow() {
        isPresented = false
        autoShownForLogin = false
        window.allowOffscreen = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.setFrame(NSRect(origin: Self.offscreenOrigin, size: Self.visibleSize), display: false)
        window.orderFrontRegardless()
        window.orderBack(nil)
    }

    func toggleWindow() {
        isPresented ? hideWindow() : showWindow()
    }

    // MARK: - 截图

    func snapshotPNG() async throws -> (Data, Int, Int) {
        let image: NSImage = try await withCheckedThrowingContinuation { cont in
            webView.takeSnapshot(with: nil) { image, error in
                if let image {
                    cont.resume(returning: image)
                } else {
                    cont.resume(throwing: error ?? APIError.internal("snapshot failed"))
                }
            }
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw APIError.internal("snapshot has no bitmap")
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw APIError.internal("PNG encoding failed")
        }
        return (png, cg.width, cg.height)
    }
}

// MARK: - WKNavigationDelegate

extension WebViewHost: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Log.debug("webview.did_finish", ["host": webView.url?.host ?? ""])
        Task { await probe() }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if SessionClassifier.observe(url: webView.url) == .loginPage {
            apply(.loginPage)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.warn("webview.did_fail", ["error": error.localizedDescription])
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.warn("webview.did_fail_provisional", ["error": error.localizedDescription])
        // 网络暂不可用时稍后重试,保证常驻。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !self.webView.isLoading, self.state != .loggedIn else { return }
            self.reload()
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.warn("webview.process_terminated")
        reload()
    }
}

// MARK: - WKUIDelegate

extension WebViewHost: WKUIDelegate {
    /// window.open / target=_blank:在同一个 WebView 内打开(登录流程偶尔使用弹窗)。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

// MARK: - WKScriptMessageHandler

extension WebViewHost: WKScriptMessageHandler {
    /// 页面侧主动上报(如检测到邮件界面就绪 / 登录页)。
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "mailReady":
            apply(.mailReady)
        case "loginPage":
            apply(.loginPage)
        case "log":
            Log.debug("page.log", ["message": (body["message"] as? String) ?? ""])
        default:
            break
        }
    }
}

// MARK: - NSWindowDelegate

extension WebViewHost: NSWindowDelegate {
    /// 关闭按钮 = 收回菜单栏,而不是销毁 WebView。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideWindow()
        return false
    }
}
