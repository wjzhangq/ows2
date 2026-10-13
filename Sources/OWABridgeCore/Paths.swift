import Foundation

/// `~/.owa-bridge` 下的文件布局。可用环境变量 `OWA_BRIDGE_HOME` 覆盖(便于测试/多实例)。
public struct BridgePaths {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> BridgePaths {
        if let override = environment["OWA_BRIDGE_HOME"], !override.isEmpty {
            return BridgePaths(root: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return BridgePaths(root: home.appendingPathComponent(".owa-bridge", isDirectory: true))
    }

    public var tokenFile: URL { root.appendingPathComponent("token") }
    public var configFile: URL { root.appendingPathComponent("config.json") }
    public var logsDirectory: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var logFile: URL { logsDirectory.appendingPathComponent("bridge.log") }

    /// 创建根目录(0700)。
    public func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
}
