import Foundation

/// 本地 Bearer token:首次启动生成,写入 `~/.owa-bridge/token`(0600)。
public enum TokenStore {
    public static func loadOrCreate(at url: URL) throws -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let existing = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            if existing.count >= 32 {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return existing
            }
        }
        let token = generate()
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return token
    }

    /// 32 字节随机数的十六进制表示(SystemRandomNumberGenerator 为 CSPRNG)。
    public static func generate(byteCount: Int = 32) -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<byteCount).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }.joined()
    }
}

public enum BearerAuth {
    /// 校验 `Authorization: Bearer <token>`,常量时间比较。
    public static func isAuthorized(header: String?, token: String) -> Bool {
        guard let header else { return false }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let prefix = "bearer "
        guard trimmed.count > prefix.count, trimmed.lowercased().hasPrefix(prefix) else { return false }
        let presented = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return constantTimeEquals(Array(presented.utf8), Array(token.utf8))
    }

    static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var diff = UInt8(a.count == b.count ? 0 : 1)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            diff |= x ^ y
        }
        return diff == 0
    }
}
