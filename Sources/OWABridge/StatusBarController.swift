import AppKit
import OWABridgeCore

/// 菜单栏图标与菜单。
@MainActor
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let paths: BridgePaths
    private let token: String
    private let port: UInt16

    init(paths: BridgePaths, token: String, port: UInt16) {
        self.paths = paths
        self.token = token
        self.port = port
        super.init()
        item.button?.image = NSImage(systemSymbolName: "envelope", accessibilityDescription: "OWA Bridge")
        item.button?.toolTip = "OWA Bridge"
        buildMenu()
        item.menu = menu
    }

    private func buildMenu() {
        menu.removeAllItems()
        menu.addItem(action("复制接口地址", #selector(copyBaseURL)))
        menu.addItem(action("复制 Token", #selector(copyToken)))
        menu.addItem(action("打开配置目录", #selector(openConfigDir)))
        menu.addItem(.separator())
        menu.addItem(action("退出 OWA Bridge", #selector(quit), key: "q"))
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

    @objc private func copyBaseURL() { copy("http://127.0.0.1:\(port)") }
    @objc private func copyToken() { copy(token) }
    @objc private func openConfigDir() { NSWorkspace.shared.open(paths.root) }
    @objc private func quit() { NSApp.terminate(nil) }
}
