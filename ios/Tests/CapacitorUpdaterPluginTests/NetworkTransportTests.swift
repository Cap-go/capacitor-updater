import Foundation
import Network
import XCTest
@testable import CapacitorUpdaterPlugin

/// Minimal loopback HTTP/1.1 server so the real URLSession transport can be exercised without the network.
private final class LoopbackHTTPServer {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    struct RecordedRequest {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "capgo.loopback-http")
    private let lock = NSLock()
    private var handler: (RecordedRequest) -> Response = { _ in Response(status: 200, body: Data()) }
    private var recorded: [RecordedRequest] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.signal()
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    var baseURL: URL {
        return URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)") ?? URL(fileURLWithPath: "/")
    }

    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func respond(_ handler: @escaping (RecordedRequest) -> Response) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let request = Self.parse(buffer) {
                self.lock.lock()
                self.recorded.append(request)
                let handler = self.handler
                self.lock.unlock()
                self.send(handler(request), on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private static func parse(_ buffer: Data) -> RecordedRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return nil
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[line.startIndex..<separator].lowercased()
            headers[name] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[headerEnd.upperBound...]
        guard body.count >= contentLength else {
            return nil
        }
        return RecordedRequest(
            method: requestLine.first ?? "",
            path: requestLine.count > 1 ? requestLine[1] : "",
            headers: headers,
            body: Data(body.prefix(contentLength))
        )
    }

    private func send(_ response: Response, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) Status\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

final class NetworkTransportTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var server: LoopbackHTTPServer!

    override func setUpWithError() throws {
        server = try LoopbackHTTPServer()
    }

    override func tearDownWithError() throws {
        server.stop()
        server = nil
    }

    private func makeUpdater() -> CapgoUpdater {
        let updater = CapgoUpdater()
        updater.setLogger(Logger(withTag: "network-transport-tests", options: Logger.Options(level: .silent)))
        updater.timeout = 5
        // The loopback test server is plain http.
        updater.httpsOnly = false
        return updater
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: server.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 5
        return request
    }

    func testPerformRequestReturnsBodyStatusAndSendsUserAgent() throws {
        server.respond { _ in .init(status: 200, body: Data("{\"ok\":true}".utf8), headers: ["Content-Type": "application/json"]) }
        let updater = makeUpdater()
        updater.appId = "com.capgo.test"

        let result = updater.performRequest(request("latest"), label: "test")

        XCTAssertFalse(result.timedOut)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.response?.statusCode, 200)
        XCTAssertEqual(result.data, Data("{\"ok\":true}".utf8))
        let userAgent = try XCTUnwrap(server.requests.first?.headers["user-agent"])
        XCTAssertTrue(userAgent.hasPrefix("CapacitorUpdater/"), userAgent)
        XCTAssertTrue(userAgent.contains("(com.capgo.test)"), userAgent)
    }

    func testPerformRequestKeepsErrorBodiesWithoutFailing() {
        server.respond { _ in .init(status: 400, body: Data("{\"error\":\"channel_not_found\"}".utf8)) }
        let result = makeUpdater().performRequest(request("channel"), label: "test")
        XCTAssertNil(result.error, "non-2xx responses are not transport errors")
        XCTAssertEqual(result.response?.statusCode, 400)
        XCTAssertEqual(result.data, Data("{\"error\":\"channel_not_found\"}".utf8))
    }

    func testPerformRequestTreatsEmptyBodyLikeAlamofireResponseData() {
        server.respond { request in
            .init(status: request.path.hasSuffix("no-content") ? 204 : 200, body: Data())
        }
        let updater = makeUpdater()

        let noContent = updater.performRequest(request("no-content"), label: "test")
        XCTAssertNil(noContent.error)
        XCTAssertNil(noContent.data)
        XCTAssertEqual(noContent.response?.statusCode, 204)

        let emptyOk = updater.performRequest(request("empty"), label: "test")
        XCTAssertNil(emptyOk.data)
        XCTAssertEqual(emptyOk.response?.statusCode, 200)
        XCTAssertEqual(emptyOk.error?.localizedDescription, "Response could not be serialized, input data was nil or zero length.")
    }

    func testPerformRequestWrapsTransportErrors() throws {
        let port = server.baseURL.port
        server.stop()
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port ?? 1)/closed")))
        request.timeoutInterval = 5

        let result = makeUpdater().performRequest(request, label: "test")

        XCTAssertFalse(result.timedOut)
        XCTAssertNil(result.response)
        let description = try XCTUnwrap(result.error?.localizedDescription)
        XCTAssertTrue(description.hasPrefix("URLSessionTask failed with error: "), description)
    }

    func testPerformRequestClassifiesURLSessionTimeouts() {
        server.respond { _ in
            Thread.sleep(forTimeInterval: 3)
            return .init(status: 200, body: Data("late".utf8))
        }
        var slowRequest = request("slow")
        slowRequest.timeoutInterval = 1

        let result = makeUpdater().performRequest(slowRequest, label: "test")

        XCTAssertTrue(result.timedOut, "a wrapped NSURLErrorTimedOut must be reported as a timeout")
        XCTAssertNotNil(result.error)
    }

    func testPerformDownloadRequestMovesBodyToTemporaryFile() throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        server.respond { _ in .init(status: 200, body: payload) }

        let result = makeUpdater().performDownloadRequest(request("bundle.zip"), label: "test")
        defer {
            if let fileURL = result.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        XCTAssertFalse(result.timedOut)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.response?.statusCode, 200)
        let fileURL = try XCTUnwrap(result.fileURL)
        XCTAssertEqual(try Data(contentsOf: fileURL), payload)
    }

    func testPerformDownloadRequestKeepsHttpErrorsAsResponses() throws {
        server.respond { _ in .init(status: 404, body: Data("missing".utf8)) }

        let result = makeUpdater().performDownloadRequest(request("missing.zip"), label: "test")
        defer {
            if let fileURL = result.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        XCTAssertNil(result.error)
        XCTAssertEqual(result.response?.statusCode, 404)
        XCTAssertNotNil(result.fileURL)
    }

    func testPerformDownloadRequestSendsRangeHeader() {
        server.respond { _ in .init(status: 206, body: Data("tail".utf8)) }
        var rangeRequest = request("partial.zip")
        rangeRequest.setValue("bytes=10-", forHTTPHeaderField: "Range")

        let result = makeUpdater().performDownloadRequest(rangeRequest, label: "test")
        if let fileURL = result.fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }

        XCTAssertEqual(result.response?.statusCode, 206)
        XCTAssertEqual(server.requests.first?.headers["range"], "bytes=10-")
    }

    func testMakeJSONPostRequestMatchesJSONEncoding() throws {
        let updater = makeUpdater()
        let built = updater.makeJSONPostRequest(urlString: "https://example.com/stats") {
            try JSONSerialization.data(withJSONObject: ["action": "set"])
        }
        let request = try built.get()
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 5)
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["action": "set"])

        let invalid = updater.makeJSONPostRequest(urlString: "") { Data() }
        XCTAssertThrowsError(try invalid.get()) { error in
            XCTAssertEqual(error.localizedDescription, "URL is not valid: ")
        }
    }
}
