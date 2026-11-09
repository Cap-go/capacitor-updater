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
        /// Close the connection without a response, like a dropped mobile link.
        var dropConnection = false
        /// Send only this many body bytes, then close, while Content-Length announces the whole body.
        var truncateBodyAt: Int?
        /// Stream the response body in chunks of this size with `chunkDelay` between writes.
        var chunkSize: Int?
        var chunkDelay: TimeInterval = 0.01
        /// When set, waits until this returns true before sending each body chunk after the first.
        var waitBeforeContinuingBody: (() -> Bool)?
        var waitBeforeContinuingBodyTimeout: TimeInterval = 2
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
    private var activeConnections = 0

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

    /// Waits until accepted connections finish or `timeout` elapses (stray URLSession tasks after invalidate).
    func drain(timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let active = activeConnections
            lock.unlock()
            if active == 0 {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func connectionOpened() {
        lock.lock()
        activeConnections += 1
        lock.unlock()
    }

    private func connectionClosed() {
        lock.lock()
        activeConnections = max(0, activeConnections - 1)
        lock.unlock()
    }

    private func accept(_ connection: NWConnection) {
        connectionOpened()
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.connectionClosed()
            }
        }
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

    /// Sends an HTTP response, optionally streaming the body in delayed chunks.
    private func send(_ response: Response, on connection: NWConnection) {
        if response.dropConnection {
            connection.cancel()
            return
        }
        var head = "HTTP/1.1 \(response.status) Status\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        let bodyData = response.truncateBodyAt.map { Data(response.body.prefix($0)) } ?? response.body

        if let chunkSize = response.chunkSize, chunkSize > 0, bodyData.count > chunkSize {
            connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
                self?.sendChunks(
                    of: bodyData, offset: 0, chunkSize: chunkSize, delay: response.chunkDelay,
                    waitBeforeContinuingBody: response.waitBeforeContinuingBody,
                    waitTimeout: response.waitBeforeContinuingBodyTimeout, on: connection
                )
            })
            return
        }

        if response.truncateBodyAt != nil {
            // Send headers and body in separate writes so a truncated body is a real mid-stream drop,
            // not one atomic read containing a short body with Content-Length still outstanding.
            let headerData = Data(head.utf8)
            connection.send(content: headerData, isComplete: false, completion: .contentProcessed { error in
                if error != nil {
                    connection.cancel()
                    return
                }
                connection.send(content: bodyData, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            })
            return
        }

        var payload = Data(head.utf8)
        payload.append(bodyData)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Recursively writes slices of `body` over `connection` separated by `delay`.
    private func sendChunks(
        of body: Data, offset: Int, chunkSize: Int, delay: TimeInterval,
        waitBeforeContinuingBody: (() -> Bool)?, waitTimeout: TimeInterval, on connection: NWConnection
    ) {
        guard offset < body.count else {
            connection.cancel()
            return
        }
        let end = min(offset + chunkSize, body.count)
        let chunk = body.subdata(in: offset..<end)
        connection.send(content: chunk, completion: .contentProcessed { [weak self] _ in
            guard let self else {
                connection.cancel()
                return
            }
            if end < body.count {
                self.queue.asyncAfter(deadline: .now() + delay) {
                    if let wait = waitBeforeContinuingBody {
                        let deadline = Date().addingTimeInterval(waitTimeout)
                        while !wait() && Date() < deadline {
                            Thread.sleep(forTimeInterval: 0.005)
                        }
                    }
                    self.sendChunks(
                        of: body, offset: end, chunkSize: chunkSize, delay: delay,
                        waitBeforeContinuingBody: waitBeforeContinuingBody, waitTimeout: waitTimeout,
                        on: connection
                    )
                }
            } else {
                connection.cancel()
            }
        })
    }
}

final class NetworkTransportTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var server: LoopbackHTTPServer!
    private var activeUpdaters: [CapgoUpdater] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = try LoopbackHTTPServer()
        activeUpdaters = []
    }

    override func tearDownWithError() throws {
        finishAllUpdaters()
        server.drain(timeout: 0.25)
        server.stop()
        server = nil
        try super.tearDownWithError()
    }

    private func makeUpdater() -> CapgoUpdater {
        let updater = CapgoUpdater()
        updater.setLogger(Logger(withTag: "network-transport-tests", options: Logger.Options(level: .silent)))
        updater.timeout = 5
        // The loopback test server is plain http.
        updater.httpsOnly = false
        activeUpdaters.append(updater)
        return updater
    }

    /// Shutdown and drop references before URLSession invalidation so the loopback port is not reused mid-flight.
    private func releaseUpdater(_ updater: CapgoUpdater) {
        updater.shutdown()
        activeUpdaters.removeAll { $0 === updater }
        server.drain(timeout: 0.25)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func finishAllUpdaters() {
        for updater in activeUpdaters {
            updater.shutdown()
        }
        activeUpdaters.removeAll()
    }

    func testManifestRecoversFromTransientStatusWithoutRestartingBundle() throws {
        let body = Data("<html>recovered \(UUID().uuidString)</html>".utf8)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try body.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let hash = CryptoCipher.calcChecksum(filePath: file)
        let lock = NSLock()
        var attempts = 0
        var postSuccessAttempts = 0
        var servedSuccess = false
        server.respond { _ in
            lock.lock()
            if servedSuccess {
                postSuccessAttempts += 1
                lock.unlock()
                return .init(status: 500, body: Data())
            }
            attempts += 1
            let status = attempts == 1 ? 503 : 200
            if status == 200 {
                servedSuccess = true
            }
            lock.unlock()
            return .init(status: status, body: status == 200 ? body : Data())
        }
        let updater = makeUpdater()
        defer { releaseUpdater(updater) }
        CryptoCipher.setLogger(Logger(withTag: "manifest-retry-test", options: Logger.Options(level: .silent)))
        let installed = try updater.downloadManifest(manifest: [ManifestEntry(
            file_name: "index.html", file_hash: hash,
            download_url: server.baseURL.appendingPathComponent(UUID().uuidString).absoluteString
        )], version: UUID().uuidString, sessionKey: "")
        defer { _ = updater.delete(id: installed.getId()) }
        // URLSession may issue an extra GET after 503 before surfacing the failure to our retry loop,
        // so expect at least one 503 and a final 200, and at most three hits on the test server.
        XCTAssertGreaterThanOrEqual(attempts, 2)
        XCTAssertLessThanOrEqual(attempts, 3)
        XCTAssertEqual(postSuccessAttempts, 0, "unexpected GET after successful download")
        let target = try updater.getBundleDirectory(id: installed.getId()).appendingPathComponent("index.html")
        XCTAssertEqual(try Data(contentsOf: target), body)
    }

    func testManifestRetriesDroppedConnections() throws {
        let body = Data("<html>reconnected \(UUID().uuidString)</html>".utf8)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try body.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let hash = CryptoCipher.calcChecksum(filePath: file)
        let lock = NSLock()
        var attempts = 0
        var postSuccessAttempts = 0
        var servedSuccess = false
        // Two drops: URLSession may replay a GET once by itself, so success needs the plugin retry.
        server.respond { _ in
            lock.lock()
            if servedSuccess {
                postSuccessAttempts += 1
                lock.unlock()
                return .init(status: 500, body: Data())
            }
            attempts += 1
            let drop = attempts <= 2
            if !drop {
                servedSuccess = true
            }
            lock.unlock()
            return .init(status: 200, body: body, dropConnection: drop)
        }
        let updater = makeUpdater()
        defer { releaseUpdater(updater) }
        CryptoCipher.setLogger(Logger(withTag: "manifest-drop-test", options: Logger.Options(level: .silent)))
        let installed = try updater.downloadManifest(manifest: [ManifestEntry(
            file_name: "index.html", file_hash: hash,
            download_url: server.baseURL.appendingPathComponent(UUID().uuidString).absoluteString
        )], version: UUID().uuidString, sessionKey: "")
        defer { _ = updater.delete(id: installed.getId()) }
        // Two drops plus URLSession's own replays can hit the server more than three times before success.
        XCTAssertGreaterThanOrEqual(attempts, 3)
        XCTAssertLessThanOrEqual(attempts, 5)
        XCTAssertEqual(postSuccessAttempts, 0, "unexpected GET after successful download")
        let target = try updater.getBundleDirectory(id: installed.getId()).appendingPathComponent("index.html")
        XCTAssertEqual(try Data(contentsOf: target), body)
    }

    func testManifestResumesInterruptedTransferInsteadOfRestarting() throws {
        var body = Data()
        for index in 0..<4096 {
            body.append(contentsOf: Array("line \(index) \(UUID().uuidString)\n".utf8))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try body.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let hash = CryptoCipher.calcChecksum(filePath: file)
        let cut = body.count / 2
        let lock = NSLock()
        var attempts = 0
        var resumedFrom: String?
        server.respond { request in
            lock.lock()
            attempts += 1
            let first = attempts == 1
            if !first { resumedFrom = request.headers["range"] }
            lock.unlock()
            let validators = ["ETag": "\"capgo-resume\"", "Accept-Ranges": "bytes"]
            if first {
                return .init(status: 200, body: body, headers: validators, truncateBodyAt: cut)
            }
            guard let range = request.headers["range"], range.hasPrefix("bytes="),
                  let start = Int(range.dropFirst("bytes=".count).split(separator: "-").first ?? "") else {
                return .init(status: 200, body: body, headers: validators)
            }
            var headers = validators
            headers["Content-Range"] = "bytes \(start)-\(body.count - 1)/\(body.count)"
            return .init(status: 206, body: body.subdata(in: start..<body.count), headers: headers)
        }
        let updater = makeUpdater()
        defer { releaseUpdater(updater) }
        CryptoCipher.setLogger(Logger(withTag: "manifest-resume-test", options: Logger.Options(level: .silent)))
        let installed = try updater.downloadManifest(manifest: [ManifestEntry(
            file_name: "app.js", file_hash: hash,
            download_url: server.baseURL.appendingPathComponent(UUID().uuidString).absoluteString
        )], version: UUID().uuidString, sessionKey: "")
        defer { _ = updater.delete(id: installed.getId()) }
        XCTAssertEqual(attempts, 2)
        // The retry continued the interrupted transfer rather than fetching from byte 0.
        let start = Int(resumedFrom?.dropFirst("bytes=".count).split(separator: "-").first ?? "") ?? 0
        XCTAssertGreaterThan(start, 0, "retry did not resume: \(resumedFrom ?? "no Range header")")
        let target = try updater.getBundleDirectory(id: installed.getId()).appendingPathComponent("app.js")
        XCTAssertEqual(try Data(contentsOf: target), body)
    }

    func testContentRangeStartParsing() {
        XCTAssertEqual(CapgoUpdater.contentRangeStart("bytes 100-199/200"), 100)
        XCTAssertEqual(CapgoUpdater.contentRangeStart("bytes 0-9/10"), 0)
        XCTAssertNil(CapgoUpdater.contentRangeStart(nil))
        XCTAssertNil(CapgoUpdater.contentRangeStart("bytes */200"))
        XCTAssertNil(CapgoUpdater.contentRangeStart("items 1-2/3"))
    }

    func testManifestRetryClassificationUnwrapsTransportErrors() {
        typealias NetworkError = CapgoUpdater.NetworkError
        for code in [URLError.Code.networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .timedOut] {
            XCTAssertTrue(CapgoUpdater.isRetryableManifestError(NetworkError.sessionTaskFailed(URLError(code))), "\(code)")
        }
        XCTAssertFalse(CapgoUpdater.isRetryableManifestError(NetworkError.sessionTaskFailed(URLError(.cancelled))))
        XCTAssertFalse(CapgoUpdater.isRetryableManifestError(NetworkError.sessionTaskFailed(URLError(.serverCertificateUntrusted))))
        XCTAssertTrue(CapgoUpdater.isRetryableManifestError(NSError(domain: "StatusCodeError", code: 503)))
        XCTAssertTrue(CapgoUpdater.isRetryableManifestError(NSError(domain: "StatusCodeError", code: 408)))
        XCTAssertFalse(CapgoUpdater.isRetryableManifestError(NSError(domain: "StatusCodeError", code: 429)))
        XCTAssertFalse(CapgoUpdater.isRetryableManifestError(NSError(domain: "StatusCodeError", code: 404)))
        XCTAssertFalse(CapgoUpdater.isRetryableManifestError(NSError(domain: "ChecksumError", code: 1)))
        XCTAssertTrue(CapgoUpdater.isRetryableManifestError(NSError(domain: CapgoUpdater.manifestResumeErrorDomain, code: 1)))
    }

    func testManifestPermanentFailuresAndRetryBudget() throws {
        for status in [404, 429, 503, 200] {
            let updater = makeUpdater()
            defer { releaseUpdater(updater) }
            CryptoCipher.setLogger(Logger(withTag: "manifest-failure-test", options: Logger.Options(level: .silent)))
            let version = UUID().uuidString
            defer {
                for bundle in updater.list(raw: true) where bundle.getVersionName() == version {
                    _ = updater.delete(id: bundle.getId())
                }
            }
            let expected = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data(UUID().uuidString.utf8).write(to: expected)
            defer { try? FileManager.default.removeItem(at: expected) }
            let hash = CryptoCipher.calcChecksum(filePath: expected)
            let before = server.requests.count
            server.respond { _ in .init(status: status, body: Data("incorrect".utf8)) }
            XCTAssertThrowsError(try updater.downloadManifest(manifest: [ManifestEntry(
                file_name: "index.html", file_hash: hash,
                download_url: server.baseURL.appendingPathComponent(UUID().uuidString).absoluteString
            )], version: version, sessionKey: ""))
            XCTAssertEqual(server.requests.count - before, status == 503 ? 3 : 1)
        }
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

    /// Verifies that chunked download responses report intermediate byte progress samples.
    func testPerformDownloadRequestReportsProgressCallbacks() throws {
        let payload = Data((0..<250_000).map { UInt8($0 % 251) })
        server.respond { _ in .init(status: 200, body: payload, chunkSize: 50_000, chunkDelay: 0.01) }

        let lock = NSLock()
        var samples: [(Int64, Int64)] = []
        let result = makeUpdater().performDownloadRequest(request("bundle-progress.zip"), label: "test") { received, expected in
            lock.lock()
            samples.append((received, expected))
            lock.unlock()
        }
        defer {
            if let fileURL = result.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        XCTAssertNil(result.error)
        XCTAssertTrue(
            samples.contains(where: { $0.0 > 0 && $0.0 < $0.1 }),
            "expected at least one intermediate sample with 0 < received < expected, got \(samples)"
        )
        if let lastSample = samples.last {
            XCTAssertEqual(lastSample.1, Int64(payload.count))
            XCTAssertGreaterThan(lastSample.0, 0)
            XCTAssertLessThanOrEqual(lastSample.0, lastSample.1)
        }
    }

    /// Verifies that HTTP error bodies are preserved on disk without reporting download progress.
    func testPerformDownloadRequestKeepsHttpErrorsAsResponses() throws {
        server.respond { _ in .init(status: 404, body: Data(repeating: 0x41, count: 64_000), chunkSize: 16_000, chunkDelay: 0.01) }

        let lock = NSLock()
        var samples: [(Int64, Int64)] = []
        let result = makeUpdater().performDownloadRequest(request("missing.zip"), label: "test") { received, expected in
            lock.lock()
            samples.append((received, expected))
            lock.unlock()
        }
        defer {
            if let fileURL = result.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        XCTAssertNil(result.error)
        XCTAssertEqual(result.response?.statusCode, 404)
        XCTAssertNotNil(result.fileURL)
        XCTAssertTrue(samples.isEmpty, "non-2xx responses must not report download progress")
    }

    /// Verifies that `downloadVerified` emits rising intermediate percentages in `10..<70` before `70%` and `100%`.
    func testDownloadZipEmitsProgressEventsFromZeroThroughOneHundred() throws {
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        }
        var writer = TestZipWriter()
        writer.addFile("index.html", Data("<html>zip-progress</html>".utf8))
        writer.addFile("assets/bundle.bin", Data((0..<300_000).map { UInt8($0 % 251) }))
        let zipPayload = writer.build()
        let tempZip = FileManager.default.temporaryDirectory.appendingPathComponent("capgo-zip-\(UUID().uuidString).zip")
        try zipPayload.write(to: tempZip)
        defer { try? FileManager.default.removeItem(at: tempZip) }
        let expectedChecksum = CryptoCipher.calcChecksum(filePath: tempZip)
        server.respond { _ in .init(status: 200, body: zipPayload, chunkSize: 60_000, chunkDelay: 0.01) }

        let updater = makeUpdater()
        CryptoCipher.setLogger(Logger(withTag: "zip-progress-test", options: Logger.Options(level: .silent)))
        var percents: [Int] = []
        updater.notifyDownloadRaw = { _, percent, _, _ in
            percents.append(percent)
        }

        let done = expectation(description: "zip download complete")
        var downloadedBundle: BundleInfo?
        var downloadError: Error?
        let downloadURL = server.baseURL.appendingPathComponent("bundle-\(UUID().uuidString).zip")
        let version = UUID().uuidString
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                downloadedBundle = try updater.downloadVerified(
                    url: downloadURL,
                    version: version,
                    sessionKey: "",
                    expectedChecksum: expectedChecksum
                )
            } catch {
                downloadError = error
            }
            DispatchQueue.main.async {
                done.fulfill()
            }
        }
        let waitResult = XCTWaiter.wait(for: [done], timeout: 10)
        XCTAssertEqual(waitResult, .completed, "zip download did not finish before teardown")
        defer {
            if let installed = downloadedBundle {
                _ = updater.delete(id: installed.getId())
            }
            releaseUpdater(updater)
        }
        XCTAssertNil(downloadError)
        XCTAssertEqual(percents.first, 0)
        XCTAssertTrue(percents.contains(where: { (10..<70).contains($0) }), "expected transfer progress in 10..<70, got \(percents)")
        XCTAssertTrue(percents.contains(70), "expected 70% completion tick, got \(percents)")
        XCTAssertTrue(percents.contains(75), "expected 75% unzip start tick, got \(percents)")
        XCTAssertTrue(percents.contains(90), "expected 90% wrap-up tick, got \(percents)")
        XCTAssertEqual(percents.last, 100)
        XCTAssertEqual(percents, percents.sorted(), "progress percentages must be non-decreasing: \(percents)")
    }

    /// Verifies that `Range` requests offset progress only when the server responds with `206 Partial Content`.
    func testPerformDownloadRequestSendsRangeHeader() {
        let tail = Data(repeating: 0x42, count: 100_000)
        let expectedTotal = Int64(10 + tail.count)
        let flowLock = NSLock()
        var resumeBody = false
        server.respond { _ in
            var response = LoopbackHTTPServer.Response(status: 206, body: tail, chunkSize: 5_000, chunkDelay: 0.02)
            response.waitBeforeContinuingBody = {
                flowLock.lock()
                let go = resumeBody
                flowLock.unlock()
                return go
            }
            return response
        }
        var rangeRequest = request("partial.zip")
        rangeRequest.setValue("bytes=10-", forHTTPHeaderField: "Range")

        let sampleLock = NSLock()
        var partialSamples: [(Int64, Int64)] = []
        let result = makeUpdater().performDownloadRequest(rangeRequest, label: "test") { received, expected in
            sampleLock.lock()
            partialSamples.append((received, expected))
            if received > 10 {
                flowLock.lock()
                resumeBody = true
                flowLock.unlock()
            }
            sampleLock.unlock()
        }
        if let fileURL = result.fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }

        XCTAssertEqual(result.response?.statusCode, 206)
        XCTAssertEqual(server.requests.first?.headers["range"], "bytes=10-")
        XCTAssertFalse(partialSamples.isEmpty)
        XCTAssertTrue(partialSamples.contains(where: { $0.0 > 10 }), "expected resumed bytes beyond the 10 byte offset, got \(partialSamples)")
        for sample in partialSamples {
            XCTAssertLessThanOrEqual(sample.0, sample.1)
            XCTAssertEqual(sample.1, expectedTotal)
        }
        if let lastPartial = partialSamples.last {
            XCTAssertEqual(lastPartial.1, expectedTotal)
            XCTAssertGreaterThan(lastPartial.0, 10)
        }

        server.respond { _ in .init(status: 200, body: tail, chunkSize: 50_000, chunkDelay: 0.01) }
        var fullSamples: [(Int64, Int64)] = []
        let fullResult = makeUpdater().performDownloadRequest(rangeRequest, label: "test") { received, expected in
            sampleLock.lock()
            fullSamples.append((received, expected))
            sampleLock.unlock()
        }
        if let fileURL = fullResult.fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        XCTAssertFalse(fullSamples.isEmpty)
        if let lastFull = fullSamples.last {
            XCTAssertEqual(lastFull.1, Int64(tail.count))
        }
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
