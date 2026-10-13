import XCTest
@testable import OWABridgeCore

final class ConfigTokenTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("owa-bridge-tests-\(UUID().uuidString)")
        try BridgePaths(root: dir).ensureRoot()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testConfigDefaultsWrittenOnFirstLoad() throws {
        let paths = BridgePaths(root: dir)
        let config = try BridgeConfig.loadOrCreate(at: paths.configFile)
        XCTAssertEqual(config, .default)
        XCTAssertEqual(config.port, 5333)
        XCTAssertFalse(config.enableDebugEval)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.configFile.path))
    }

    func testConfigPartialFileUsesDefaults() throws {
        let paths = BridgePaths(root: dir)
        try Data(#"{"port": 6000, "enableDebugEval": true, "requestTimeoutSeconds": 0}"#.utf8).write(to: paths.configFile)
        let config = try BridgeConfig.loadOrCreate(at: paths.configFile)
        XCTAssertEqual(config.port, 6000)
        XCTAssertTrue(config.enableDebugEval)
        XCTAssertEqual(config.requestTimeoutSeconds, 1) // clamped
        XCTAssertEqual(config.logLevel, .info)
    }

    func testTokenIsGeneratedOnceAndPersisted() throws {
        let paths = BridgePaths(root: dir)
        let t1 = try TokenStore.loadOrCreate(at: paths.tokenFile)
        let t2 = try TokenStore.loadOrCreate(at: paths.tokenFile)
        XCTAssertEqual(t1, t2)
        XCTAssertEqual(t1.count, 64)
        let perms = try FileManager.default.attributesOfItem(atPath: paths.tokenFile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testBearerAuth() {
        XCTAssertTrue(BearerAuth.isAuthorized(header: "Bearer abc", token: "abc"))
        XCTAssertTrue(BearerAuth.isAuthorized(header: "bearer   abc ", token: "abc"))
        XCTAssertFalse(BearerAuth.isAuthorized(header: "Bearer abd", token: "abc"))
        XCTAssertFalse(BearerAuth.isAuthorized(header: "Bearer ab", token: "abc"))
        XCTAssertFalse(BearerAuth.isAuthorized(header: "Basic abc", token: "abc"))
        XCTAssertFalse(BearerAuth.isAuthorized(header: nil, token: "abc"))
    }

    func testLogLevelOrdering() {
        XCTAssertTrue(LogLevel.debug < .info)
        XCTAssertTrue(LogLevel.warn < .error)
    }
}
