import AppKit
import OWABridgeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private(set) var paths = BridgePaths.resolve()
    private(set) var config = BridgeConfig.default
    private(set) var token = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try paths.ensureRoot()
            config = try BridgeConfig.loadOrCreate(at: paths.configFile)
            token = try TokenStore.loadOrCreate(at: paths.tokenFile)
        } catch {
            fatalStartup("无法初始化 \(paths.root.path):\(error.localizedDescription)")
            return
        }
        Log.shared.configure(level: config.logLevel, file: config.logToFile ? paths.logFile : nil)
        Log.info("app.start", ["version": BridgeVersion.current, "port": Int(config.port), "home": paths.root.path])

        statusBar = StatusBarController(paths: paths, token: token, port: config.port)
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
