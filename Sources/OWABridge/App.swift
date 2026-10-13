import AppKit

@main
enum OWABridgeMain {
    private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        // 无 Dock 图标(打包后 Info.plist 的 LSUIElement 也会生效;此处保证 `swift run` 时一致)。
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
