import XCTest
@testable import OWABridgeCore

final class HTTPTests: XCTestCase {
    private func parse(_ s: String) -> HTTPParseResult { HTTPRequestParser.parse(Data(s.utf8)) }

    func testParsesSimpleGet() throws {
        guard case .complete(let req) = parse("GET /messages?top=5&unread=true HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer x\r\n\r\n") else {
            return XCTFail("expected complete")
        }
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/messages")
        XCTAssertEqual(req.query["top"], "5")
        XCTAssertTrue(req.boolQuery("unread"))
        XCTAssertEqual(req.header("authorization"), "Bearer x")
    }

    func testIncompleteUntilHeaderAndBodyArrive() {
        guard case .incomplete = parse("GET / HTTP/1.1\r\nHost: x\r\n") else { return XCTFail() }
        guard case .incomplete = parse("POST /debug/eval HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc") else { return XCTFail() }
        guard case .complete(let req) = parse("POST /debug/eval HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc") else { return XCTFail() }
        XCTAssertEqual(String(data: req.body, encoding: .utf8), "abc")
    }

    func testRejectsMalformedAndChunked() {
        guard case .invalid = parse("GARBAGE\r\n\r\n") else { return XCTFail() }
        guard case .invalid = parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") else { return XCTFail() }
        guard case .invalid = parse("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n") else { return XCTFail() }
    }

    func testQueryDecoding() {
        let q = HTTPRequest.parseQuery("folder=My%20Folder&selector=%5Brole%3Dmain%5D&flag&x=a+b")
        XCTAssertEqual(q["folder"], "My Folder")
        XCTAssertEqual(q["selector"], "[role=main]")
        XCTAssertEqual(q["flag"], "")
        XCTAssertEqual(q["x"], "a b")
    }

    func testResponseSerialization() {
        let data = HTTPResponse.json(200, ["ok": true]).serialize()
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(s.contains("Content-Type: application/json; charset=utf-8\r\n"))
        XCTAssertTrue(s.contains("Content-Length: 11\r\n"))
        XCTAssertTrue(s.hasSuffix("\r\n\r\n{\"ok\":true}"))
    }

    func testErrorBody() throws {
        let resp = HTTPResponse.error(.sessionExpired())
        XCTAssertEqual(resp.status, 401)
        let obj = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        XCTAssertEqual(obj?["error"] as? String, "session_expired")
    }

    func testRouterMatching() async {
        let router = Router()
        router.add("GET", "/messages") { _, _ in HTTPResponse(status: 200) }
        router.add("GET", "/messages/*id") { _, p in HTTPResponse(status: 200, body: Data(p["id"]!.utf8)) }
        router.add("POST", "/debug/eval") { _, _ in HTTPResponse(status: 200) }

        guard case .found = router.match(method: "GET", path: "/messages/") else { return XCTFail() }
        guard case .found(let h, let params) = router.match(method: "GET", path: "/messages/AAMk%2Babc/def=") else { return XCTFail() }
        XCTAssertEqual(params["id"], "AAMk+abc/def=")
        let resp = await h(HTTPRequest(method: "GET", target: "/"), params)
        XCTAssertEqual(String(data: resp.body, encoding: .utf8), "AAMk+abc/def=")
        guard case .methodNotAllowed = router.match(method: "GET", path: "/debug/eval") else { return XCTFail() }
        guard case .notFound = router.match(method: "GET", path: "/nope") else { return XCTFail() }
    }

    func testMessagesQueryValidation() {
        let ok = MessagesQuery.parse(HTTPRequest(method: "GET", target: "/messages?top=100&folder=sent&unread=1"))
        XCTAssertEqual(try ok.get(), MessagesQuery(folder: "sent", top: 50, unread: true, debug: false))
        let defaults = MessagesQuery.parse(HTTPRequest(method: "GET", target: "/messages"))
        XCTAssertEqual(try defaults.get(), MessagesQuery())
        guard case .failure(let e) = MessagesQuery.parse(HTTPRequest(method: "GET", target: "/messages?top=abc")) else { return XCTFail() }
        XCTAssertEqual(e.code, "bad_request")
    }

    func testPageErrorMapping() {
        XCTAssertEqual(APIError.fromPage(code: "session_expired", message: "", status: nil).status, 401)
        XCTAssertEqual(APIError.fromPage(code: "not_found", message: "", status: nil).status, 404)
        XCTAssertEqual(APIError.fromPage(code: "weird", message: "", status: 418).status, 418)
    }
}

final class PageResultTests: XCTestCase {
    func testDecodeSuccess() throws {
        let r = try PageResult.decode(#"{"ok":true,"status":200,"provider":"internalFetchProvider","data":{"count":1},"debug":{"durationMs":3}}"#)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.provider, "internalFetchProvider")
        XCTAssertEqual((r.data as? [String: Any])?["count"] as? Int, 1)
        XCTAssertNil(r.apiError)
    }

    func testDecodeError() throws {
        let r = try PageResult.decode(#"{"ok":false,"status":401,"error":"session_expired","message":"login"}"#)
        XCTAssertEqual(r.apiError, APIError(status: 401, code: "session_expired", message: "login"))
    }

    func testDecodeGarbage() {
        XCTAssertThrowsError(try PageResult.decode("42"))
    }
}

final class DebugEvalTests: XCTestCase {
    func testExpressionGetsReturn() {
        XCTAssertEqual(DebugEval.functionBody(for: " document.title "), "return (document.title);")
    }

    func testStatementsAreKept() {
        XCTAssertEqual(DebugEval.functionBody(for: "const a = 1; return a"), "const a = 1; return a")
        XCTAssertEqual(DebugEval.functionBody(for: "const a = 1\nreturn a"), "const a = 1\nreturn a")
    }
}
