import CapgoUpdaterCore
import CommonCrypto
import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

/// The `http_request` host callback over URLSession, against a local HTTP/1.1 server
/// (`localhost`: ATS and the engine allow cleartext to it).
final class HttpTransportTests: XCTestCase {
    private var server: LocalHttpServer!
    /// Fresh bytes per run: the engine's delta cache would serve a file it saw before.
    private let unique = Data((0..<100_000).map { _ in UInt8.random(in: 0...255) })

    override func setUpWithError() throws {
        let unique = unique
        server = try LocalHttpServer { request, connection in
            switch request.path {
            case "/hello":
                connection.respond("HTTP/1.1 200 OK\r\nX-Test: yes\r\nContent-Length: 5\r\n\r\nhello")
            case "/echo":
                connection.respond("HTTP/1.1 200 OK\r\nContent-Length: \(request.body.count)\r\n\r\n", body: request.body)
            case "/file":
                let body = Data(repeating: 0x61, count: 100_000)
                connection.respond("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n", body: body)
            case "/unique":
                connection.respond("HTTP/1.1 200 OK\r\nContent-Length: \(unique.count)\r\n\r\n", body: unique)
            case "/big":
                let body = Data(repeating: 0x62, count: 20 * 1024 * 1024)
                connection.respond("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n", body: body)
            case "/redirect":
                connection.respond("HTTP/1.1 302 Found\r\nLocation: /hello\r\nContent-Length: 0\r\n\r\n")
            case "/slow":
                connection.send("HTTP/1.1 200 OK\r\nContent-Length: 100000000\r\n\r\n")
                while connection.send(String(repeating: "x", count: 1024)) {
                    usleep(10_000)
                }
            case "/hang":
                // Reads the request, never answers.
                Thread.sleep(forTimeInterval: 8)
            default:
                connection.respond("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
            }
        }
    }

    override func tearDown() {
        server.stop()
    }

    private func url(_ path: String) -> String {
        "http://localhost:\(server.port)\(path)"
    }

    func testMemoryModeDeliversHeadAndBodyAndProtocol() {
        let probe = TransportProbe()
        let outcome = probe.run(url: url("/echo"), method: "POST", headers: [["User-Agent", "CapgoTest"]], body: Data("ping".utf8))
        XCTAssertEqual(outcome.code, CAPGO_HTTP_COMPLETED, "\(outcome.reply)")
        XCTAssertEqual(outcome.reply["protocol"] as? String, "http/1.1")
        XCTAssertEqual(probe.status, 200)
        XCTAssertEqual(String(bytes: probe.body, encoding: .utf8), "ping")
        XCTAssertEqual(server.requests.first?.header("user-agent"), "CapgoTest")

        let hello = TransportProbe()
        XCTAssertEqual(hello.run(url: url("/hello")).code, CAPGO_HTTP_COMPLETED)
        XCTAssertTrue(hello.headers.contains { $0[0].lowercased() == "x-test" && $0[1] == "yes" }, "\(hello.headers)")
    }

    func testFileModeAppendsTheBodyAndReportsTotals() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("capgo-transport-\(UUID().uuidString)")
        try Data("prefix".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let probe = TransportProbe()
        let outcome = probe.run(url: url("/file"), bodyPath: path.path)
        XCTAssertEqual(outcome.code, CAPGO_HTTP_COMPLETED, "\(outcome.reply)")
        XCTAssertTrue(probe.body.isEmpty, "file mode sends no bytes through the sink")
        XCTAssertEqual(probe.progress.last, 100_000)
        XCTAssertEqual(probe.progress, probe.progress.sorted())
        let written = try Data(contentsOf: path)
        XCTAssertEqual(written.count, 6 + 100_000)
        XCTAssertEqual(written.prefix(6), Data("prefix".utf8))
    }

    /// A slow sink makes the transport suspend the task (over 8 MB queued) and resume it.
    func testASlowSinkStillGetsTheWholeBody() {
        let probe = TransportProbe()
        probe.slowCalls = 20
        XCTAssertEqual(probe.run(url: url("/big")).code, CAPGO_HTTP_COMPLETED)
        XCTAssertEqual(probe.body.count, 20 * 1024 * 1024)
    }

    func testRedirectsAreReturnedNotFollowed() {
        let probe = TransportProbe()
        XCTAssertEqual(probe.run(url: url("/redirect")).code, CAPGO_HTTP_COMPLETED)
        XCTAssertEqual(probe.status, 302)
        XCTAssertTrue(probe.headers.contains { $0[0].lowercased() == "location" && $0[1] == "/hello" })
        XCTAssertEqual(server.requests.map(\.path), ["/redirect"])
    }

    func testASinkCancelStopsTheRequest() {
        let probe = TransportProbe()
        probe.cancelAfterBytes = 1
        let started = Date()
        let outcome = probe.run(url: url("/slow"))
        XCTAssertEqual(outcome.code, CAPGO_HTTP_FAILED)
        XCTAssertEqual(outcome.reply["error"] as? String, "cancelled")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testIdleTimeoutIsReportedAsTimeout() {
        let probe = TransportProbe()
        let outcome = probe.run(url: url("/hang"), timeoutMs: 1000)
        XCTAssertEqual(outcome.code, CAPGO_HTTP_FAILED)
        XCTAssertEqual(outcome.reply["error"] as? String, "timeout", "\(outcome.reply)")
        XCTAssertNil(probe.status)
    }

    func testRefusedConnectionsAndBadUrlsMapToEngineKinds() {
        let refused = TransportProbe().run(url: "http://localhost:1/")
        XCTAssertEqual(refused.code, CAPGO_HTTP_FAILED)
        XCTAssertEqual(refused.reply["error"] as? String, "network", "\(refused.reply)")
        let invalid = TransportProbe().run(url: "ftp://localhost/")
        XCTAssertEqual(invalid.reply["error"] as? String, "invalid_url")
    }

    /// The engine sends a manifest file through the transport into its partial file.
    func testEngineDownloadsGoThroughTheTransport() throws {
        let content = unique
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        content.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(content.count), &digest) }
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let updater = StatsRecordingCapgoUpdater()
        defer { updater.shutdown() }
        let version = "transport-\(UUID().uuidString.prefix(8))"
        let installed = try updater.downloadManifest(
            manifest: [ManifestEntry(file_name: "a.bin", file_hash: hash, download_url: url("/unique"))],
            version: version,
            sessionKey: ""
        )
        let id = try XCTUnwrap(installed["id"] as? String)
        defer { updater.deleteBundle(id: id) }
        XCTAssertEqual(installed["status"] as? String, "pending")
        XCTAssertEqual(server.requests.map(\.path), ["/unique"])
        XCTAssertEqual(server.requests.first?.header("accept-encoding"), "identity")
        // URLSession adds Accept-Language; the engine's own client never does.
        XCTAssertNotNil(server.requests.first?.header("accept-language"), "\(server.requests.first?.headers ?? [:])")
    }
}

/// Calls `CapgoHttpTransport.callback` like the engine does and records what the sink got.
private final class TransportProbe {
    var status: Int32?
    var headers: [[String]] = []
    var body = Data()
    var progress: [UInt64] = []
    var cancelAfterBytes: Int?
    /// The first calls of on_data sleep 50 ms each.
    var slowCalls = 0

    private static func probe(_ handle: UnsafeMutableRawPointer?) -> TransportProbe? {
        handle.map { Unmanaged<TransportProbe>.fromOpaque($0).takeUnretainedValue() }
    }

    /// A sink recording into this probe (valid while the probe lives).
    private func makeSink() -> CapgoHttpSink {
        CapgoHttpSink(
            handle: Unmanaged.passUnretained(self).toOpaque(),
            on_head: { handle, status, headers in
                guard let probe = TransportProbe.probe(handle), let headers else {
                    return 1
                }
                probe.status = status
                let json = Data(bytes: headers, count: strlen(headers))
                probe.headers = (try? JSONSerialization.jsonObject(with: json)) as? [[String]] ?? []
                return 0
            },
            on_data: { handle, data, length in
                guard let probe = TransportProbe.probe(handle), let data else {
                    return 1
                }
                probe.body.append(data, count: length)
                if probe.slowCalls > 0 {
                    probe.slowCalls -= 1
                    usleep(50_000)
                }
                if let limit = probe.cancelAfterBytes, probe.body.count >= limit {
                    return 1
                }
                return 0
            },
            on_progress: { handle, written in
                guard let probe = TransportProbe.probe(handle) else {
                    return 1
                }
                probe.progress.append(written)
                return 0
            }
        )
    }

    func run(
        url: String,
        method: String = "GET",
        headers: [[String]] = [],
        body: Data? = nil,
        timeoutMs: UInt64 = 10_000,
        bodyPath: String? = nil
    ) -> (code: Int32, reply: [String: Any]) {
        let headersJson = CapgoCore.jsonString(headers) ?? "[]"
        var sink = makeSink()
        var result: UnsafeMutablePointer<CChar>?
        let bodyBytes = body.map { [UInt8]($0) }
        let code: Int32 = method.withCString { method in
            url.withCString { url in
                headersJson.withCString { headersJson in
                    withOptionalCString(bodyPath) { path in
                        (bodyBytes ?? []).withUnsafeBufferPointer { bytes in
                            var request = CapgoHttpRequest(
                                method: method,
                                url: url,
                                headers_json: headersJson,
                                body: bodyBytes == nil ? nil : bytes.baseAddress,
                                body_length: bytes.count,
                                timeout_ms: timeoutMs,
                                body_path: path
                            )
                            return CapgoHttpTransport.callback(nil, &request, &sink, &result)
                        }
                    }
                }
            }
        }
        var reply: [String: Any] = [:]
        if let result {
            reply = (try? JSONSerialization.jsonObject(with: Data(bytes: result, count: strlen(result)))) as? [String: Any] ?? [:]
            free(result)
        }
        return (code, reply)
    }

    private func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let value else {
            return body(nil)
        }
        return value.withCString { body($0) }
    }
}
