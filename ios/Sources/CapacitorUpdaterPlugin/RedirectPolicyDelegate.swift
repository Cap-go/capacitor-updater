/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation

/// URLSession delegate that refuses redirects from HTTPS to plain HTTP unless explicitly allowed.
/// A refused redirect cancels the task, so callers see a transport error instead of the 3xx body.
final class RedirectPolicyDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    private let lock = NSLock()
    private var allowDowngrade = false
    private var httpsOnlyEnabled = true
    private var streams: [Int: StreamState] = [:]

    private final class StreamState {
        let fileURL: URL
        let handle: FileHandle
        let resumedBytes: Int64
        let onProgress: ((Int64, Int64) -> Void)?
        let completion: (HTTPURLResponse?, Error?) -> Void
        var response: HTTPURLResponse?
        var received: Int64 = 0
        var finished = false

        init(
            fileURL: URL,
            handle: FileHandle,
            resumedBytes: Int64,
            onProgress: ((Int64, Int64) -> Void)?,
            completion: @escaping (HTTPURLResponse?, Error?) -> Void
        ) {
            self.fileURL = fileURL
            self.handle = handle
            self.resumedBytes = resumedBytes
            self.onProgress = onProgress
            self.completion = completion
        }
    }
    /// When true every redirect target must be https, whatever `allowHttpsToHttpRedirect` says.
    var httpsOnly: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return httpsOnlyEnabled
        }
        set {
            lock.lock()
            httpsOnlyEnabled = newValue
            lock.unlock()
        }
    }
    /// Called when a downgrade redirect is refused. Must not retain the updater strongly.
    var onBlockedRedirect: ((URL?, URL?) -> Void)?

    var allowHttpsToHttpRedirect: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return allowDowngrade
        }
        set {
            lock.lock()
            allowDowngrade = newValue
            lock.unlock()
        }
    }

    static func isHttpsToHttpDowngrade(from source: URL?, to target: URL?) -> Bool {
        guard let sourceScheme = source?.scheme?.lowercased(), let targetScheme = target?.scheme?.lowercased() else {
            return false
        }
        return sourceScheme == "https" && targetScheme == "http"
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let source = response.url ?? task.currentRequest?.url
        if httpsOnly && request.url?.scheme?.lowercased() != "https" {
            onBlockedRedirect?(source, request.url)
            completionHandler(nil)
            task.cancel()
            return
        }
        if !allowHttpsToHttpRedirect && Self.isHttpsToHttpDowngrade(from: source, to: request.url) {
            onBlockedRedirect?(source, request.url)
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    /// Stream a data-task body to `fileURL` so a mid-transfer failure still leaves
    /// partial bytes for a later Range retry. Completion runs once.
    func registerStream(
        for task: URLSessionTask,
        fileURL: URL,
        resumedBytes: Int64,
        onProgress: ((Int64, Int64) -> Void)?,
        completion: @escaping (HTTPURLResponse?, Error?) -> Void
    ) throws {
        if !FileManager.default.createFile(atPath: fileURL.path, contents: nil) {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create download file at \(fileURL.path)"]
            )
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        let state = StreamState(
            fileURL: fileURL,
            handle: handle,
            resumedBytes: resumedBytes,
            onProgress: onProgress,
            completion: completion
        )
        lock.lock()
        streams[task.taskIdentifier] = state
        lock.unlock()
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        streams[dataTask.taskIdentifier]?.response = response as? HTTPURLResponse
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let state = streams[dataTask.taskIdentifier], !state.finished else {
            lock.unlock()
            return
        }
        state.handle.write(data)
        state.received += Int64(data.count)
        let response = state.response ?? dataTask.response as? HTTPURLResponse
        let received = state.received
        let resumedBytes = state.resumedBytes
        let onProgress = state.onProgress
        lock.unlock()

        guard let onProgress, let response, (200..<300).contains(response.statusCode) else {
            return
        }
        let expectedBody = response.expectedContentLength
        let expected = expectedBody > 0 ? expectedBody : received
        let baseline = CapgoUpdater.shouldAppendHttpBody(statusCode: response.statusCode, existingBytes: resumedBytes)
            ? resumedBytes
            : 0
        onProgress(baseline + received, baseline + expected)
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard let state = streams.removeValue(forKey: task.taskIdentifier), !state.finished else {
            lock.unlock()
            return
        }
        state.finished = true
        let response = state.response ?? task.response as? HTTPURLResponse
        try? state.handle.close()
        lock.unlock()
        let resultError: Error?
        if let error {
            resultError = CapgoUpdater.NetworkError.sessionTaskFailed(error)
        } else {
            resultError = nil
        }
        state.completion(response, resultError)
    }
}
