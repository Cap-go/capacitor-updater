/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import CapgoUpdaterCore

/// The engine's `http_request` host callback: its requests go through URLSession, so they get
/// HTTP/3 (tried first), HTTP/2 and HTTP/1.1 from the OS, the system proxy, and ATS with
/// `NSPinnedDomains` (no custom trust handling here: URLSession's default evaluation applies).
///
/// The engine keeps its own rules on top (redirects, cleartext policy, body caps, length
/// checks, resume, retries): this transport never follows a redirect and hands every response
/// back as it came. The sink is called on the thread that called `http_request`, one call at a
/// time, before it returns (C ABI contract): the session delegate only queues events, the
/// calling thread delivers them, and bundle files are written on that thread too.
final class CapgoHttpTransport: NSObject, URLSessionDataDelegate {
    static let shared = CapgoHttpTransport()

    /// Queued body bytes above which a task is suspended (the engine thread writes slower than
    /// the network delivers), and below which it resumes.
    fileprivate static let suspendAbove = 8 * 1024 * 1024
    fileprivate static let resumeBelow = 2 * 1024 * 1024

    private let lock = NSLock()
    private var exchanges: [Int: Exchange] = [:]

    /// One process-wide session: HTTP/2 and HTTP/3 multiplex the engine's parallel downloads
    /// (up to 32) on one connection per host. Ephemeral, like the engine's own client: no URL
    /// cache, cookies or stored credentials (a cached or cookie-dependent answer would differ
    /// from what the backend sends). 32 connections per host keep the HTTP/1.1 fallback as
    /// parallel as the engine. No `waitsForConnectivity`: offline fails at once and the engine
    /// retries (or the Android-style job scheduler does).
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 32
        let queue = OperationQueue()
        queue.name = "app.capgo.updater.http"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    typealias Callback = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<CapgoHttpRequest>?,
        UnsafePointer<CapgoHttpSink>?,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32

    /// `http_request` member of `CapgoHostCallbacks`.
    static let callback: Callback = { _, request, sink, result in
        guard let request, let sink else {
            return CAPGO_HTTP_UNAVAILABLE
        }
        let (code, reply) = shared.perform(request.pointee, sink.pointee)
        if let reply, let result, let json = CapgoCore.jsonString(reply) {
            result.pointee = strdup(json)
        }
        return code
    }

    // MARK: - Calling thread

    /// Runs one request and reports it to `sink`. Returns the `http_request` code and result object.
    func perform(_ request: CapgoHttpRequest, _ sink: CapgoHttpSink) -> (Int32, [String: Any]?) {
        let urlText = request.url.map { String(cString: $0) } ?? ""
        guard let urlRequest = Self.urlRequest(request, url: urlText) else {
            return (CAPGO_HTTP_FAILED, ["error": "invalid_url", "message": "Invalid URL: \(urlText)"])
        }
        let exchange = Exchange()
        let task = session.dataTask(with: urlRequest)
        exchange.task = task
        lock.lock()
        exchanges[task.taskIdentifier] = exchange
        lock.unlock()
        task.resume()

        var delivery = Delivery(sink: sink, bodyPath: request.body_path.map { String(cString: $0) })
        var completion: Error?
        loop: while true {
            switch exchange.next() {
            case .head(let response):
                delivery.head(response)
            case .data(let data):
                delivery.data(data)
            case .done(let error):
                completion = error
                break loop
            }
            if delivery.stopRequested {
                delivery.stopRequested = false
                task.cancel()
                exchange.resumeIfSuspended()
            }
        }
        delivery.close()

        if delivery.stopped {
            if let ioError = delivery.ioError {
                return (CAPGO_HTTP_FAILED, ["error": "io", "message": ioError])
            }
            return (CAPGO_HTTP_FAILED, ["error": "cancelled", "message": "Request cancelled"])
        }
        if let completion {
            return (CAPGO_HTTP_FAILED, ["error": Self.errorKind(completion), "message": completion.localizedDescription])
        }
        guard delivery.headSent else {
            return (CAPGO_HTTP_FAILED, ["error": "network", "message": "No HTTP response"])
        }
        var reply: [String: Any] = [:]
        reply["protocol"] = exchange.protocolName
        return (CAPGO_HTTP_COMPLETED, reply)
    }

    /// The URLRequest for an engine request; nil when the URL is not http(s).
    static func urlRequest(_ request: CapgoHttpRequest, url urlText: String) -> URLRequest? {
        guard let url = URL(string: urlText), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.map { String(cString: $0) } ?? "GET"
        // HTTP/3 first; the OS falls back to HTTP/2 or HTTP/1.1 over TCP.
        urlRequest.assumesHTTP3Capable = true
        // URLSession's request timeout is an idle timeout, as the engine expects.
        urlRequest.timeoutInterval = request.timeout_ms > 0 ? Double(request.timeout_ms) / 1000 : 60
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in headerPairs(request.headers_json) {
            urlRequest.addValue(value, forHTTPHeaderField: name)
        }
        if let body = request.body {
            urlRequest.httpBody = Data(bytes: body, count: request.body_length)
        }
        return urlRequest
    }

    static func headerPairs(_ json: UnsafePointer<CChar>?) -> [(String, String)] {
        guard let json,
              let pairs = try? JSONSerialization.jsonObject(with: Data(bytes: json, count: strlen(json))) as? [[Any]] else {
            return []
        }
        return pairs.compactMap { pair in
            guard pair.count == 2, let name = pair[0] as? String, let value = pair[1] as? String else {
                return nil
            }
            return (name, value)
        }
    }

    static func headersJson(_ response: HTTPURLResponse) -> String {
        let pairs: [[String]] = response.allHeaderFields.compactMap { name, value in
            guard let name = name as? String else {
                return nil
            }
            return [name, "\(value)"]
        }
        return CapgoCore.jsonString(pairs) ?? "[]"
    }

    /// Error kind for the engine (`timeout`, `tls`, `invalid_url`, `cancelled`, `network`).
    static func errorKind(_ error: Error) -> String {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else {
            return "network"
        }
        switch error.code {
        case NSURLErrorTimedOut:
            return "timeout"
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL,
             // ATS refused plain HTTP: the engine reports its own cleartext refusal as an invalid URL
             // (definitive, not retried), so this is one too.
             NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "invalid_url"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return "tls"
        case NSURLErrorCancelled:
            // Not cancelled by the engine (that is reported before): a refused server trust
            // (pinning) cancels the load with the peer trust attached.
            return error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey] != nil ? "tls" : "cancelled"
        default:
            return "network"
        }
    }

    // MARK: - Session delegate (serial queue)

    private func exchange(for task: URLSessionTask, remove: Bool = false) -> Exchange? {
        lock.lock()
        defer { lock.unlock() }
        return remove ? exchanges.removeValue(forKey: task.taskIdentifier) : exchanges[task.taskIdentifier]
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let response = response as? HTTPURLResponse {
            exchange(for: dataTask)?.push(.head(response))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        exchange(for: dataTask)?.push(.data(data))
    }

    /// The engine follows redirects itself (count limit, HTTPS -> HTTP guard): the 3xx is the response.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    /// Delivered before `didCompleteWithError` on this serial queue.
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        exchange(for: task)?.setProtocol(metrics.transactionMetrics.last?.networkProtocolName)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        exchange(for: task, remove: true)?.push(.done(error))
    }
}

/// Hands one response to the engine's sink on the calling thread: the head, then the body to
/// `on_data` or appended to `bodyPath` with `on_progress` totals. A refusal (non-zero) or a
/// file error stops the request.
private struct Delivery {
    let sink: CapgoHttpSink
    let bodyPath: String?
    private(set) var headSent = false
    private(set) var stopped = false
    private(set) var ioError: String?
    /// Set when the caller must cancel the task.
    var stopRequested = false
    private var file: FileHandle?
    private var written: UInt64 = 0

    init(sink: CapgoHttpSink, bodyPath: String?) {
        self.sink = sink
        self.bodyPath = bodyPath
    }

    private mutating func stop(_ error: String? = nil) {
        if !stopped {
            stopped = true
            stopRequested = true
            ioError = error
        }
    }

    mutating func head(_ response: HTTPURLResponse) {
        guard !stopped, !headSent else {
            return
        }
        headSent = true
        let headers = CapgoHttpTransport.headersJson(response)
        let verdict = headers.withCString { sink.on_head?(sink.handle, Int32(response.statusCode), $0) ?? 1 }
        guard verdict == 0 else {
            stop()
            return
        }
        if let bodyPath {
            // The engine prepared the file (created, truncated or kept for a resume): append.
            guard let handle = FileHandle(forWritingAtPath: bodyPath) else {
                stop("Cannot open \(bodyPath) for writing")
                return
            }
            handle.seekToEndOfFile()
            file = handle
        }
    }

    mutating func data(_ data: Data) {
        guard !stopped, headSent else {
            return
        }
        let verdict: Int32
        if let file {
            do {
                try file.write(contentsOf: data)
            } catch {
                stop(error.localizedDescription)
                return
            }
            written += UInt64(data.count)
            verdict = sink.on_progress?(sink.handle, written) ?? 1
        } else {
            verdict = data.withUnsafeBytes { bytes in
                sink.on_data?(sink.handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) ?? 1
            }
        }
        if verdict != 0 {
            stop()
        }
    }

    mutating func close() {
        try? file?.close()
        file = nil
    }
}

/// Events of one request, from the delegate queue to the calling thread.
private final class Exchange {
    enum Event {
        case head(HTTPURLResponse)
        case data(Data)
        case done(Error?)
    }

    private let condition = NSCondition()
    private var events: [Event] = []
    private var queuedBytes = 0
    private var suspended = false
    private var negotiated: String?
    weak var task: URLSessionTask?

    var protocolName: String? {
        condition.lock()
        defer { condition.unlock() }
        return negotiated
    }

    func setProtocol(_ name: String?) {
        condition.lock()
        negotiated = name
        condition.unlock()
    }

    func push(_ event: Event) {
        condition.lock()
        events.append(event)
        if case .data(let data) = event {
            queuedBytes += data.count
            if queuedBytes > CapgoHttpTransport.suspendAbove, !suspended {
                suspended = true
                task?.suspend()
            }
        }
        condition.signal()
        condition.unlock()
    }

    /// The next event, waiting for it. URLSession's idle timeout ends a stalled request.
    func next() -> Event {
        condition.lock()
        defer { condition.unlock() }
        while events.isEmpty {
            condition.wait()
        }
        let event = events.removeFirst()
        if case .data(let data) = event {
            queuedBytes -= data.count
            if suspended, queuedBytes < CapgoHttpTransport.resumeBelow {
                suspended = false
                task?.resume()
            }
        }
        return event
    }

    func resumeIfSuspended() {
        condition.lock()
        defer { condition.unlock() }
        if suspended {
            suspended = false
            task?.resume()
        }
    }
}
