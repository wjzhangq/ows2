import AppKit

/// 菜单栏图标与菜单。
@MainActor
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "envelope", accessibilityDescription: "OWA Bridge")
        item.button?.toolTip = "OWA Bridge"

        let quit = NSMenuItem(title: "退出 OWA Bridge", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
