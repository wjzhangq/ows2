import Foundation
import OWABridgeCore

/// 定位并读取 `extractor.js`:
/// 1. 环境变量 `OWA_BRIDGE_EXTRACTOR`(开发时热替换)
/// 2. App bundle 的 Contents/Resources/extractor.js
/// 3. 源码树中的 Resources/extractor.js(`swift run` 开发模式)
enum ExtractorScript {
    static func load() throws -> (source: String, url: URL) {
        for url in candidates() where FileManager.default.fileExists(atPath: url.path) {
            return (try String(contentsOf: url, encoding: .utf8), url)
        }
        throw APIError.internal("extractor.js not found (looked in: \(candidates().map(\.path).joined(separator: ", ")))")
    }

    private static func candidates() -> [URL] {
        var urls: [URL] = []
        if let override = ProcessInfo.processInfo.environment["OWA_BRIDGE_EXTRACTOR"], !override.isEmpty {
            urls.append(URL(fileURLWithPath: override))
        }
        if let bundled = Bundle.main.url(forResource: "extractor", withExtension: "js") {
            urls.append(bundled)
        }
        // Sources/OWABridge/ExtractorScript.swift -> <repo>/Resources/extractor.js
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        urls.append(repoRoot.appendingPathComponent("Resources/extractor.js"))
        return urls
    }
}
