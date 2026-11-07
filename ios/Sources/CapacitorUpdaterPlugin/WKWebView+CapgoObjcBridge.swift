import Foundation
import WebKit

// Swift overlay WebKit callAsyncJavaScript autolinks libswiftWebKit.dylib (iOS 26+ on device).
// Use __callAsyncJavaScript via capgo_callAsyncJavaScriptInPage for sub-iOS 26 launch. Issue #1004.
extension WKWebView {
    @MainActor
    func capgo_callAsyncJavaScriptInPage(
        _ script: String,
        arguments: [String: Any] = [:],
        completionHandler: @escaping (Any?, Error?) -> Void
    ) {
        self.__callAsyncJavaScript(
            script,
            arguments: arguments,
            inFrame: nil,
            in: .page,
            completionHandler: completionHandler
        )
    }
}
