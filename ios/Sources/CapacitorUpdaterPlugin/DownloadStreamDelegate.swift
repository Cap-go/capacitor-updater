/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation

/// Streams download bodies to disk on a delegate URLSession without breaking data-task completion handlers elsewhere.
final class DownloadStreamDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    private let redirectPolicy: RedirectPolicyDelegate
    private let lock = NSLock()
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

    init(redirectPolicy: RedirectPolicyDelegate) {
        self.redirectPolicy = redirectPolicy
    }

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
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirectPolicy.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request,
            completionHandler: completionHandler
        )
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
        do {
            try state.handle.write(contentsOf: data)
        } catch {
            state.finished = true
            streams.removeValue(forKey: dataTask.taskIdentifier)
            let response = state.response ?? dataTask.response as? HTTPURLResponse
            try? state.handle.close()
            lock.unlock()
            dataTask.cancel()
            state.completion(response, error)
            return
        }
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
