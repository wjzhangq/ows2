import Foundation

/// 运行配置,对应 `~/.owa-bridge/config.json`。缺失字段取默认值。
public struct BridgeConfig: Codable, Equatable {
    /// HTTP 端口(只绑定 127.0.0.1)。
    public var port: UInt16
    /// 单个 WebView 请求的超时(秒)。
    public var requestTimeoutSeconds: Double
    /// 是否开放 `/debug/eval`(可在页面上下文执行任意 JS,默认关闭)。
    public var enableDebugEval: Bool
    /// 日志级别:debug / info / warn / error。
    public var logLevel: LogLevel
    /// 是否把日志写入 `~/.owa-bridge/logs/bridge.log`(不含邮件正文)。
    public var logToFile: Bool
    /// WebView 初始地址。
    public var startURL: String
    /// 未登录/会话失效时是否自动弹出窗口。
    public var autoShowLoginWindow: Bool
    /// 追加在 WebKit 默认 UA 之后的应用名(让登录页识别为 Safari)。
    public var applicationNameForUserAgent: String
    /// 抽取脚本运行的 JS world:`client`(隔离,默认)或 `page`(与 OWA 页面共享全局)。
    public var scriptWorld: ScriptWorld
    /// 后台登录态探测间隔(秒)。
    public var probeIntervalSeconds: Double

    public enum ScriptWorld: String, Codable, Equatable {
        case client
        case page
    }

    public init(
        port: UInt16 = 5333,
        requestTimeoutSeconds: Double = 10,
        enableDebugEval: Bool = false,
        logLevel: LogLevel = .info,
        logToFile: Bool = true,
        startURL: String = "https://outlook.office.com/mail/",
        autoShowLoginWindow: Bool = true,
        applicationNameForUserAgent: String = "Version/17.4 Safari/605.1.15",
        scriptWorld: ScriptWorld = .client,
        probeIntervalSeconds: Double = 30
    ) {
        self.port = port
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.enableDebugEval = enableDebugEval
        self.logLevel = logLevel
        self.logToFile = logToFile
        self.startURL = startURL
        self.autoShowLoginWindow = autoShowLoginWindow
        self.applicationNameForUserAgent = applicationNameForUserAgent
        self.scriptWorld = scriptWorld
        self.probeIntervalSeconds = probeIntervalSeconds
    }

    public static let `default` = BridgeConfig()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BridgeConfig.default
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? d.port
        requestTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .requestTimeoutSeconds) ?? d.requestTimeoutSeconds
        enableDebugEval = try c.decodeIfPresent(Bool.self, forKey: .enableDebugEval) ?? d.enableDebugEval
        logLevel = try c.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? d.logLevel
        logToFile = try c.decodeIfPresent(Bool.self, forKey: .logToFile) ?? d.logToFile
        startURL = try c.decodeIfPresent(String.self, forKey: .startURL) ?? d.startURL
        autoShowLoginWindow = try c.decodeIfPresent(Bool.self, forKey: .autoShowLoginWindow) ?? d.autoShowLoginWindow
        applicationNameForUserAgent = try c.decodeIfPresent(String.self, forKey: .applicationNameForUserAgent) ?? d.applicationNameForUserAgent
        scriptWorld = try c.decodeIfPresent(ScriptWorld.self, forKey: .scriptWorld) ?? d.scriptWorld
        probeIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .probeIntervalSeconds) ?? d.probeIntervalSeconds
    }

    /// 读取配置;文件不存在时写出默认配置,方便用户编辑。解析失败抛错(不静默覆盖用户文件)。
    public static func loadOrCreate(at url: URL) throws -> BridgeConfig {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            var config = try JSONDecoder().decode(BridgeConfig.self, from: data)
            config.clamp()
            return config
        }
        let config = BridgeConfig.default
        try config.write(to: url)
        return config
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// 把明显不合理的值拉回安全范围。
    public mutating func clamp() {
        if port == 0 { port = BridgeConfig.default.port }
        requestTimeoutSeconds = min(max(requestTimeoutSeconds, 1), 120)
        probeIntervalSeconds = min(max(probeIntervalSeconds, 5), 3600)
    }
}
