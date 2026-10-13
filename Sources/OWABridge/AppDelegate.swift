import AppKit
import OWABridgeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var host: WebViewHost?
    private var bridge: JSBridge?
    private var api: BridgeAPI?
    private var server: HTTPServer?
    private var activity: NSObjectProtocol?
    private(set) var paths = BridgePaths.resolve()
    private(set) var config = BridgeConfig.default
    private(set) var token = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        let extractor: (source: String, url: URL)
        do {
            try paths.ensureRoot()
            config = try BridgeConfig.loadOrCreate(at: paths.configFile)
            token = try TokenStore.loadOrCreate(at: paths.tokenFile)
            extractor = try ExtractorScript.load()
        } catch {
            fatalStartup("初始化失败(\(paths.root.path)):\(error)")
            return
        }
        Log.shared.configure(level: config.logLevel, file: config.logToFile ? paths.logFile : nil)
        Log.info("app.start", ["version": BridgeVersion.current, "port": Int(config.port), "home": paths.root.path, "extractor": extractor.url.path])

        // 防 App Nap:窗口离屏时 WebView 仍需及时执行 JS。
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "OWA Bridge keeps the Outlook WebView responsive for local API requests"
        )

        let host = WebViewHost(config: config, extractorSource: extractor.source)
        self.host = host

        let statusBar = StatusBarController(paths: paths, token: token, port: config.port, host: host)
        self.statusBar = statusBar
        host.observeState { [weak statusBar] state in statusBar?.update(state: state) }

        let bridge = JSBridge(host: host, timeout: config.requestTimeoutSeconds)
        self.bridge = bridge
        host.prober = { [weak bridge] in
            guard let bridge, let call = try? await bridge.run("probe", timeout: 5), call.result.ok,
                  let data = call.result.data as? [String: Any] else { return nil }
            if data["onLoginPage"] as? Bool == true { return .loginPage }
            return data["mailReady"] as? Bool == true ? .mailReady : .owaLoading
        }

        let api = BridgeAPI(config: config, token: token, host: host, bridge: bridge)
        self.api = api
        let server = HTTPServer(port: config.port) { request in
            await api.handle(request)
        }
        server.onStateChange = { [weak statusBar] text in
            Task { @MainActor in statusBar?.update(serverStatus: text) }
        }
        do {
            try server.start()
        } catch {
            Log.error("http.start_failed", ["error": "\(error)"])
            statusBar.update(serverStatus: "failed: \(error)")
        }
        self.server = server

        host.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func fatalStartup(_ message: String) {
        Log.error("app.start_failed", ["message": message])
        let alert = NSAlert()
        alert.messageText = "OWA Bridge 启动失败"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }
}
