import XCTest
import WebKit
@testable import CapacitorUpdaterPlugin

private final class RecordingWebView: WKWebView {
    private(set) var lastScript: String?

    override func evaluateJavaScript(_ javaScriptString: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        lastScript = javaScriptString
        completionHandler?(nil, nil)
    }
}

final class LoggerSecurityTests: XCTestCase {
    private let injectionPayloads = [
        "hello\");alert(1)//",
        "line\nbreak",
        "`backtick`",
        "</script><script>alert(1)</script>",
        "back\\slash",
        "line\u{2028}separator",
        "para\u{2029}graph",
        "{\"error\":\"Internal Server Error\",\"detail\":\"');fetch('https://evil.test')//\"}",
        "HTTP/1.1 500\r\n\r\n<script>alert(1)</script>"
    ]

    func testToJSStringLiteralEscapesQuotesNewlinesBackslashesAndLineSeparators() throws {
        let logger = Logger(withTag: "LoggerSecurityTests")

        for payload in injectionPayloads {
            try assertRoundTripJSStringLiteral(logger: logger, value: payload)
        }
    }

    func testBuildWebViewConsoleScriptUsesAllowlistedConsoleMethodsOnly() {
        let logger = Logger(withTag: "CapgoUpdater")

        XCTAssertEqual(
            "console.error(\(logger.toJSStringLiteral("🟢 CapgoUpdater : test")))",
            logger.buildWebViewConsoleScript(level: .error, label: "🟢", tag: "CapgoUpdater", message: "test")
        )
        XCTAssertEqual(
            "console.warn(\(logger.toJSStringLiteral("🟠 CapgoUpdater : test")))",
            logger.buildWebViewConsoleScript(level: .warn, label: "🟠", tag: "CapgoUpdater", message: "test")
        )
        XCTAssertEqual(
            "console.info(\(logger.toJSStringLiteral("🟢 CapgoUpdater : test")))",
            logger.buildWebViewConsoleScript(level: .info, label: "🟢", tag: "CapgoUpdater", message: "test")
        )
        XCTAssertEqual(
            "console.debug(\(logger.toJSStringLiteral("🔎 CapgoUpdater : test")))",
            logger.buildWebViewConsoleScript(level: .debug, label: "🔎", tag: "CapgoUpdater", message: "test")
        )
        XCTAssertNil(logger.buildWebViewConsoleScript(level: .silent, label: "", tag: "CapgoUpdater", message: "test"))
    }

    func testBuildWebViewConsoleScriptEscapesTagAndMessagePayloads() throws {
        let logger = Logger(withTag: "LoggerSecurityTests")

        for payload in injectionPayloads {
            let script = logger.buildWebViewConsoleScript(
                level: .error,
                label: "🔴",
                tag: "tag\");alert(1)//",
                message: payload
            )
            XCTAssertNotNil(script)
            try assertSafeConsoleScript(
                script!,
                consoleMethod: "error",
                expectedPayload: "🔴 tag\");alert(1)// : \(payload)",
                logger: logger
            )
        }
    }

    func testLogAtLevelForwardsEscapedScriptToEvaluateJavaScript() throws {
        let logger = Logger(withTag: "CapgoUpdater")
        let webView = RecordingWebView(frame: .zero, configuration: WKWebViewConfiguration())
        logger.setWebView(webView: webView)

        let maliciousMessage = "hello\");alert(1)//"
        logger.log(atLevel: .error, message: maliciousMessage)

        let expectation = expectation(description: "evaluateJavaScript dispatched")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        try assertSafeConsoleScript(
            XCTUnwrap(webView.lastScript),
            consoleMethod: "error",
            expectedPayload: "🔴 CapgoUpdater : \(maliciousMessage)",
            logger: logger
        )
    }

    func testCapWebViewLogPayloadTruncatesOversizedMessages() {
        let logger = Logger(withTag: "LoggerSecurityTests")
        let oversized = String(repeating: "x", count: Logger.maxWebViewLogPayloadChars + 10)
        let capped = logger.capWebViewLogPayload(oversized)

        XCTAssertTrue(capped.hasSuffix("..."))
        XCTAssertLessThanOrEqual(capped.utf8.count, Logger.maxWebViewLogPayloadChars + 3)
    }

    func testCapWebViewLogPayloadPreservesValidUtf8BoundariesForCombiningMarks() {
        let logger = Logger(withTag: "LoggerSecurityTests")
        let combiningMarkPayload = String(repeating: "\u{0301}", count: Logger.maxWebViewLogPayloadChars + 10)
        let capped = logger.capWebViewLogPayload(combiningMarkPayload)

        XCTAssertTrue(capped.hasSuffix("..."))
        XCTAssertNotNil(String(data: Data(capped.utf8), encoding: .utf8))
    }

    private func assertSafeConsoleScript(
        _ script: String,
        consoleMethod: String,
        expectedPayload: String,
        logger: Logger
    ) throws {
        let expectedScript = "console.\(consoleMethod)(\(logger.toJSStringLiteral(expectedPayload)))"
        XCTAssertEqual(expectedScript, script)

        let prefix = "console.\(consoleMethod)("
        let quotedArg = String(script.dropFirst(prefix.count).dropLast())
        let data = Data(("[" + quotedArg + "]").utf8)
        let decodedPayloads = try JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(expectedPayload, decodedPayloads[0])
    }

    private func assertRoundTripJSStringLiteral(logger: Logger, value: String) throws {
        let quoted = logger.toJSStringLiteral(value)
        XCTAssertTrue(quoted.hasPrefix("\""))
        XCTAssertTrue(quoted.hasSuffix("\""))

        let data = Data(("[" + quoted + "]").utf8)
        let decodedPayloads = try JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(value, decodedPayloads[0])
    }
}
