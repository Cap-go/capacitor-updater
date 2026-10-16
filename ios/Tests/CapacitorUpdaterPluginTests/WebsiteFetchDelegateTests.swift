import XCTest
@testable import CapacitorUpdaterPlugin

private final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (response, data) = handler(request)
        if let location = response.value(forHTTPHeaderField: "Location"), let target = URL(string: location, relativeTo: url) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Deliver in chunks like a real download.
        var offset = 0
        while offset < data.count {
            let end = min(offset + 64 * 1024, data.count)
            client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class WebsiteFetchDelegateTests: XCTestCase {
    private func fetch(_ url: URL, maxBytes: Int) -> (Data?, Error?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let delegate = WebsiteFetchDelegate(maxBytes: maxBytes)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let done = expectation(description: "fetch")
        var result: (Data?, Error?) = (nil, nil)
        let task = session.dataTask(with: url)
        delegate.register(task) { data, _, error in
            result = (data, error)
            done.fulfill()
        }
        task.resume()
        wait(for: [done], timeout: 10)
        return result
    }

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    func testReturnsBodyUnderTheLimit() {
        StubProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(count: 1000))
        }
        let (data, error) = fetch(URL(string: "https://app.example.com/a.js")!, maxBytes: 4096)
        XCTAssertNil(error)
        XCTAssertEqual(data?.count, 1000)
    }

    func testCancelsBodyOverTheLimitWhileStreaming() {
        StubProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(count: 512 * 1024))
        }
        let (data, error) = fetch(URL(string: "https://app.example.com/big.js")!, maxBytes: 100 * 1024)
        XCTAssertNil(data)
        XCTAssertNotNil(error)
    }

    func testBlocksCrossOriginRedirect() {
        StubProtocol.handler = { request in
            if request.url?.host == "app.example.com" {
                return (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://evil.example.com/a.js"])!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("evil".utf8))
        }
        let (data, error) = fetch(URL(string: "https://app.example.com/a.js")!, maxBytes: 4096)
        XCTAssertNotEqual(data, Data("evil".utf8))
        XCTAssertNotNil(error)
    }
}
