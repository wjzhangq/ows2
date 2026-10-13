import XCTest
@testable import OWABridgeCore

final class SessionTests: XCTestCase {
    func testTransitions() {
        XCTAssertEqual(SessionMachine.next(.loading, .loginPage), .notLoggedIn)
        XCTAssertEqual(SessionMachine.next(.notLoggedIn, .mailReady), .loggedIn)
        XCTAssertEqual(SessionMachine.next(.loggedIn, .loginPage), .expired)
        XCTAssertEqual(SessionMachine.next(.loggedIn, .authFailed), .expired)
        XCTAssertEqual(SessionMachine.next(.expired, .loginPage), .expired)
        XCTAssertEqual(SessionMachine.next(.expired, .owaLoading), .expired)
        XCTAssertEqual(SessionMachine.next(.expired, .mailReady), .loggedIn)
        XCTAssertEqual(SessionMachine.next(.loading, .owaLoading), .loading)
    }

    func testClassifier() {
        XCTAssertEqual(SessionClassifier.observe(url: URL(string: "https://outlook.office.com/mail/")), .owaLoading)
        XCTAssertEqual(SessionClassifier.observe(url: URL(string: "https://login.microsoftonline.com/common/oauth2")), .loginPage)
        XCTAssertEqual(SessionClassifier.observe(url: URL(string: "https://sso.contoso.com/adfs/ls")), .loginPage)
        XCTAssertNil(SessionClassifier.observe(url: URL(string: "about:blank")))
    }
}
