/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation

/// URLSession delegate that refuses redirects from HTTPS to plain HTTP unless explicitly allowed.
/// A refused redirect cancels the task, so callers see a transport error instead of the 3xx body.
final class RedirectPolicyDelegate: NSObject, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var allowDowngrade = false
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
        if !allowHttpsToHttpRedirect && Self.isHttpsToHttpDowngrade(from: source, to: request.url) {
            onBlockedRedirect?(source, request.url)
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }
}
