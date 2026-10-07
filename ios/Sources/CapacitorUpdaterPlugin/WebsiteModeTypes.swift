/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation

extension WebsiteModeUpdater {
    enum WebsiteModeError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    /// Parsed body of `GET website_live?app_id=`. Unknown fields are ignored.
    struct LiveResponse: Equatable {
        let allowed: Bool
        let mode: String
        let websiteUrl: String
        let downloadBaseUrl: String
        let checkIntervalSeconds: Int
        let reason: String

        var isCapgoMode: Bool {
            mode == WebsiteModeUpdater.modeCapgo
        }

        /// True only when the website may be downloaded and its URL is usable.
        var isWebsiteUpdateAllowed: Bool {
            allowed && mode == WebsiteModeUpdater.modeWebsite && WebsiteModeUpdater.parseHttpsUrl(websiteUrl) != nil
        }

        static func parse(_ data: Data?) -> LiveResponse? {
            guard let data, !data.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let json = object as? [String: Any] else {
                return nil
            }
            let interval: Int
            if let number = json["check_interval_seconds"] as? NSNumber {
                interval = min(max(0, number.intValue), WebsiteModeUpdater.maxCheckIntervalSeconds)
            } else {
                interval = 0
            }
            return LiveResponse(
                allowed: (json["allowed"] as? Bool) ?? false,
                mode: (json["mode"] as? String) ?? "",
                websiteUrl: (json["website_url"] as? String) ?? "",
                downloadBaseUrl: (json["download_base_url"] as? String) ?? "",
                checkIntervalSeconds: interval,
                reason: (json["reason"] as? String) ?? ""
            )
        }
    }

    struct FetchResponse {
        let statusCode: Int
        let data: Data
        let contentType: String

        var isSuccess: Bool {
            (200..<300).contains(statusCode)
        }
    }

    struct Asset: Equatable {
        let url: URL
        let required: Bool
        /// For JS code chunk references: every candidate URL of the reference. The update fails
        /// unless at least one of them downloads; each single candidate may still 404.
        var requiredCandidates: [URL] = []
    }
}

/// Session delegate for website-mode fetches:
/// - every redirect hop must stay on the requested origin, because files are
///   saved under the requested path and another origin must never supply code;
/// - bodies are capped while they stream in, so an oversized response is
///   cancelled before it is fully buffered in memory.
final class WebsiteFetchDelegate: NSObject, URLSessionDataDelegate {
    typealias Completion = (Data?, URLResponse?, Error?) -> Void

    private struct TaskState {
        var data = Data()
        var response: URLResponse?
        var tooLarge = false
        let completion: Completion
    }

    private let maxBytes: Int
    private let lock = NSLock()
    private var states: [Int: TaskState] = [:]

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func register(_ task: URLSessionTask, completion: @escaping Completion) {
        lock.lock()
        states[task.taskIdentifier] = TaskState(completion: completion)
        lock.unlock()
    }

    private func update(_ task: URLSessionTask, _ change: (inout TaskState) -> Void) {
        lock.lock()
        if var state = states[task.taskIdentifier] {
            change(&state)
            states[task.taskIdentifier] = state
        }
        lock.unlock()
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url,
              let target = request.url,
              WebsiteModeUpdater.isSameOrigin(original, target) else {
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let declaredTooLarge = response.expectedContentLength > Int64(maxBytes)
        update(dataTask) { state in
            state.response = response
            state.tooLarge = declaredTooLarge
        }
        completionHandler(declaredTooLarge ? .cancel : .allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var exceeded = false
        update(dataTask) { state in
            guard !state.tooLarge else {
                return
            }
            if state.data.count + data.count > maxBytes {
                state.tooLarge = true
                state.data = Data()
                exceeded = true
            } else {
                state.data.append(data)
            }
        }
        if exceeded {
            dataTask.cancel()
        }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state else {
            return
        }
        if state.tooLarge {
            state.completion(nil, state.response, WebsiteModeUpdater.WebsiteModeError.failed("Asset too large"))
            return
        }
        state.completion(error == nil ? state.data : nil, state.response ?? task.response, error)
    }
}
