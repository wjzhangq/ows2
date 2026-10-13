import Foundation

public enum LogLevel: String, Codable, Comparable, CaseIterable {
    case debug, info, warn, error

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

/// 结构化日志:每行一个 JSON 对象,写 stderr,可选写文件。
/// 约定:调用方不得把邮件正文/预览写入日志。
public final class Log {
    public static let shared = Log()

    private let lock = NSLock()
    private var level: LogLevel = .info
    private var fileHandle: FileHandle?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init() {}

    public func configure(level: LogLevel, file: URL?) {
        lock.lock()
        defer { lock.unlock() }
        self.level = level
        try? fileHandle?.close()
        fileHandle = nil
        if let file {
            let fm = FileManager.default
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !fm.fileExists(atPath: file.path) {
                fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                fileHandle = handle
            }
        }
    }

    public func log(_ level: LogLevel, _ event: String, _ fields: [String: Any] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        guard level >= self.level else { return }
        var obj: [String: Any] = fields
        obj["ts"] = formatter.string(from: Date())
        obj["level"] = level.rawValue
        obj["event"] = event
        let data = (try? JSONSerialization.data(withJSONObject: Self.sanitize(obj), options: [.sortedKeys])) ?? Data("{\"event\":\"log_encode_failed\"}".utf8)
        var line = data
        line.append(0x0A)
        FileHandle.standardError.write(line)
        fileHandle?.write(line)
    }

    public static func debug(_ event: String, _ fields: [String: Any] = [:]) { shared.log(.debug, event, fields) }
    public static func info(_ event: String, _ fields: [String: Any] = [:]) { shared.log(.info, event, fields) }
    public static func warn(_ event: String, _ fields: [String: Any] = [:]) { shared.log(.warn, event, fields) }
    public static func error(_ event: String, _ fields: [String: Any] = [:]) { shared.log(.error, event, fields) }

    /// 只保留 JSON 可序列化的值,其他转成字符串。
    static func sanitize(_ obj: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in obj {
            switch v {
            case is String, is Bool, is Int, is Double, is NSNull:
                out[k] = v
            case let n as NSNumber:
                out[k] = n
            case let d as [String: Any]:
                out[k] = sanitize(d)
            default:
                out[k] = String(describing: v)
            }
        }
        return out
    }
}
