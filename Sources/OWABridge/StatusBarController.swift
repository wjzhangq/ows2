import AppKit
import OWABridgeCore

/// 菜单栏图标与菜单:登录态 / 显示窗口 / 重新加载 / 复制接口信息 / 退出。
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let paths: BridgePaths
    private let token: String
    private let port: UInt16
    private weak var host: WebViewHost?

    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let serverItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var toggleItem: NSMenuItem!
    private var state: SessionState = .loading

    init(paths: BridgePaths, token: String, port: UInt16, host: WebViewHost) {
        self.paths = paths
        self.token = token
        self.port = port
        self.host = host
        super.init()
        buildMenu()
        menu.delegate = self
        item.menu = menu
        update(state: .loading)
        update(serverStatus: "starting")
    }

    private func buildMenu() {
        stateItem.isEnabled = false
        serverItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(serverItem)
        menu.addItem(.separator())
        toggleItem = action("显示窗口", #selector(toggleWindow), key: "o")
        menu.addItem(toggleItem)
        menu.addItem(action("重新加载 Outlook", #selector(reload), key: "r"))
        menu.addItem(.separator())
        menu.addItem(action("复制接口地址", #selector(copyBaseURL)))
        menu.addItem(action("复制 Token", #selector(copyToken)))
        menu.addItem(action("打开配置目录", #selector(openConfigDir)))
        menu.addItem(.separator())
        menu.addItem(action("退出 OWA Bridge", #selector(quit), key: "q"))
    }

    func update(state: SessionState) {
        self.state = state
        let symbol: String
        switch state {
        case .loggedIn: symbol = "envelope.fill"
        case .loading: symbol = "envelope"
        case .notLoggedIn, .expired: symbol = "exclamationmark.triangle"
        }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "OWA Bridge: \(state.displayText)")
        item.button?.toolTip = "OWA Bridge — \(state.displayText)"
        stateItem.title = "状态:\(state.displayText)"
    }

    func update(serverStatus: String) {
        serverItem.title = "接口:127.0.0.1:\(port)(\(serverStatus))"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        toggleItem.title = (host?.isPresented ?? false) ? "隐藏窗口" : "显示窗口"
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        mi.target = self
        return mi
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    @objc private func toggleWindow() { host?.toggleWindow() }
    @objc private func reload() { host?.reload() }
    @objc private func copyBaseURL() { copy("http://127.0.0.1:\(port)") }
    @objc private func copyToken() { copy(token) }
    @objc private func openConfigDir() { NSWorkspace.shared.open(paths.root) }
    @objc private func quit() { NSApp.terminate(nil) }
}
