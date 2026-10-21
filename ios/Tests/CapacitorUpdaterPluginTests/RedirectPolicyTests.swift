import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

final class RedirectPolicyTests: XCTestCase {
    private func redirect(
        _ delegate: RedirectPolicyDelegate,
        from source: String,
        to target: String
    ) -> (URLRequest?, URLSessionTask) {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: source)!)
        let response = HTTPURLResponse(url: URL(string: source)!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
        var result: URLRequest?
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: target)!)) { request in
            result = request
        }
        return (result, task)
    }

    func testDowngradeDetection() {
        XCTAssertTrue(RedirectPolicyDelegate.isHttpsToHttpDowngrade(from: URL(string: "https://a.com/x"), to: URL(string: "http://b.com/y")))
        XCTAssertTrue(RedirectPolicyDelegate.isHttpsToHttpDowngrade(from: URL(string: "HTTPS://a.com/x"), to: URL(string: "HTTP://a.com/x")))
        XCTAssertFalse(RedirectPolicyDelegate.isHttpsToHttpDowngrade(from: URL(string: "https://a.com/x"), to: URL(string: "https://b.com/y")))
        XCTAssertFalse(RedirectPolicyDelegate.isHttpsToHttpDowngrade(from: URL(string: "http://a.com/x"), to: URL(string: "http://b.com/y")))
        XCTAssertFalse(RedirectPolicyDelegate.isHttpsToHttpDowngrade(from: URL(string: "http://a.com/x"), to: URL(string: "https://b.com/y")))
        XCTAssertFalse(RedirectPolicyDelegate.isHttpsToHttpDowngrade(from: nil, to: URL(string: "http://b.com/y")))
    }

    func testBlocksHttpsToHttpRedirectByDefault() {
        let delegate = RedirectPolicyDelegate()
        var blocked = false
        delegate.onBlockedRedirect = { _, _ in blocked = true }
        let (request, task) = redirect(delegate, from: "https://api.capgo.app/updates", to: "http://evil.example/bundle.zip")
        XCTAssertNil(request)
        XCTAssertTrue(blocked)
        XCTAssertNotEqual(task.state, .suspended)
    }

    func testAllowsHttpsToHttpRedirectWhenEnabled() {
        let delegate = RedirectPolicyDelegate()
        delegate.httpsOnly = false
        delegate.allowHttpsToHttpRedirect = true
        let (request, _) = redirect(delegate, from: "https://api.capgo.app/updates", to: "http://example.com/bundle.zip")
        XCTAssertEqual(request?.url?.absoluteString, "http://example.com/bundle.zip")
    }

    func testAllowsSafeRedirects() {
        let delegate = RedirectPolicyDelegate()
        XCTAssertNotNil(redirect(delegate, from: "https://a.com/x", to: "https://b.com/y").0)
        delegate.httpsOnly = false
        XCTAssertNotNil(redirect(delegate, from: "http://a.com/x", to: "https://b.com/y").0)
        XCTAssertNotNil(redirect(delegate, from: "http://a.com/x", to: "http://b.com/y").0)
    }

    func testUpdaterBlocksDowngradeByDefault() {
        let updater = CapgoUpdater()
        XCTAssertFalse(updater.allowHttpsToHttpRedirect)
        updater.allowHttpsToHttpRedirect = true
        XCTAssertTrue(updater.allowHttpsToHttpRedirect)
    }
}
