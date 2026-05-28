import XCTest
@testable import CapacitorUpdaterPlugin
import Capacitor
import Version

extension CapacitorUpdaterTests {
    func testShouldReportUncleanForegroundExitOnlyOnce() {
        XCTAssertTrue(AppHealthTracker.shouldReportUncleanForegroundExit(
            previousSessionId: "session-1",
            lastReportedSessionId: nil,
            wasForeground: true
        ))
        XCTAssertFalse(AppHealthTracker.shouldReportUncleanForegroundExit(
            previousSessionId: "session-1",
            lastReportedSessionId: "session-1",
            wasForeground: true
        ))
        XCTAssertFalse(AppHealthTracker.shouldReportUncleanForegroundExit(
            previousSessionId: "session-2",
            lastReportedSessionId: nil,
            wasForeground: false
        ))
        XCTAssertFalse(AppHealthTracker.shouldReportUncleanForegroundExit(
            previousSessionId: "",
            lastReportedSessionId: nil,
            wasForeground: true
        ))
    }

    func testReportsPreviousUncleanForegroundExitAsAppCrashStat() {
        let defaults = UserDefaults.standard
        let keys = [
            "CapacitorUpdater.appSessionId",
            "CapacitorUpdater.appSessionForeground",
            "CapacitorUpdater.appSessionStartedAt",
            "CapacitorUpdater.lastReportedUncleanSessionId"
        ]
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer { keys.forEach { defaults.removeObject(forKey: $0) } }

        defaults.set("session-unclean", forKey: "CapacitorUpdater.appSessionId")
        defaults.set(true, forKey: "CapacitorUpdater.appSessionForeground")
        defaults.set("1760000000000", forKey: "CapacitorUpdater.appSessionStartedAt")

        let implementation = HealthStatsCapgoUpdater()
        let tracker = AppHealthTracker(implementation: implementation)

        tracker.reportPreviousUncleanForegroundExit()

        XCTAssertEqual(implementation.sentStatsActions, ["app_crash"])
        XCTAssertEqual(implementation.lastStatsVersionName, "1.0.0")
        XCTAssertEqual(implementation.lastStatsOldVersionName, "")
        XCTAssertEqual(implementation.lastStatsMetadata?["exit_reason"], "unclean_foreground_exit")
        XCTAssertEqual(implementation.lastStatsMetadata?["exit_source"], "ios_session_marker")
        XCTAssertEqual(implementation.lastStatsMetadata?["previous_session_id"], "session-unclean")
        XCTAssertEqual(implementation.lastStatsMetadata?["session_started_at"], "1760000000000")

        implementation.sentStatsActions.removeAll()
        tracker.reportPreviousUncleanForegroundExit()

        XCTAssertTrue(implementation.sentStatsActions.isEmpty)
    }

    func testReportsMemoryWarningAsHealthStat() {
        let implementation = HealthStatsCapgoUpdater()
        let tracker = AppHealthTracker(implementation: implementation)

        tracker.reportMemoryWarning()

        XCTAssertEqual(implementation.sentStatsActions, ["app_memory_warning"])
        XCTAssertEqual(implementation.lastStatsVersionName, "1.0.0")
        XCTAssertEqual(implementation.lastStatsOldVersionName, "")
        XCTAssertEqual(implementation.lastStatsMetadata, ["source": "ios_memory_warning"])
    }

    func testMapsWebViewErrorTypesToStatsActions() {
        XCTAssertEqual(WebViewStatsReporter.statsAction(for: "javascript_error"), "webview_javascript_error")
        XCTAssertEqual(WebViewStatsReporter.statsAction(for: "unhandled_rejection"), "webview_unhandled_rejection")
        XCTAssertEqual(WebViewStatsReporter.statsAction(for: "resource_error"), "webview_resource_error")
        XCTAssertEqual(
            WebViewStatsReporter.statsAction(for: "security_policy_violation"),
            "webview_security_policy_violation"
        )
        XCTAssertEqual(WebViewStatsReporter.statsAction(for: "webview_unclean_restart"), "webview_unclean_restart")
        XCTAssertEqual(WebViewStatsReporter.statsAction(for: "render_process_gone"), "webview_render_process_gone")
        XCTAssertEqual(
            WebViewStatsReporter.statsAction(for: "web_content_process_terminated"),
            "webview_content_process_terminated"
        )
        XCTAssertEqual(WebViewStatsReporter.statsAction(for: "unknown"), "webview_javascript_error")
    }

    func testBuildWebViewErrorMetadataKeepsUsefulFields() {
        let metadata = WebViewStatsReporter.buildMetadata([
            "type": "javascript_error",
            "message": "boom",
            "source": "app.js",
            "line": "10",
            "column": "20",
            "stack": String(repeating: "x", count: 3_000),
            "href": "capacitor://localhost",
            "session_id": "session-1"
        ])

        XCTAssertEqual(metadata["error_type"], "javascript_error")
        XCTAssertEqual(metadata["message"], "boom")
        XCTAssertEqual(metadata["source"], "app.js")
        XCTAssertEqual(metadata["line"], "10")
        XCTAssertEqual(metadata["column"], "20")
        XCTAssertEqual(metadata["href"], "capacitor://localhost")
        XCTAssertEqual(metadata["session_id"], "session-1")
        XCTAssertEqual(metadata["stack"]?.count, 2_048)
        XCTAssertNil(metadata["tag_name"])
    }

    func testBuildWebViewErrorMetadataSanitizesUrlValues() {
        let scheme = "https"
        let host = "example.com"
        let userInfo = ["user", "value"].joined(separator: ":") + "@"
        let sourceQuery = "cache=123"
        let hrefQuery = "debug=true"
        let metadata = WebViewStatsReporter.buildMetadata([
            "source": "\(scheme)://\(userInfo)\(host):8443/assets/app.js?\(sourceQuery)#L10",
            "href": "\(scheme)://\(host)/users/123456/dashboard?\(hrefQuery)#frag",
            "previous_href": "app.js?\(sourceQuery)#frag"
        ])

        XCTAssertEqual(metadata["source"], "\(scheme)://\(host):8443/assets/app.js")
        XCTAssertEqual(metadata["href"], "\(scheme)://\(host)/users/redacted/dashboard")
        XCTAssertEqual(metadata["previous_href"], "app.js")
        XCTAssertFalse(metadata["source"]?.contains(sourceQuery) ?? true)
        XCTAssertFalse(metadata["href"]?.contains(hrefQuery) ?? true)
    }

    func testWebViewStatsReporterScriptCapturesRuntimeAndRestartSignals() {
        let script = WebViewStatsReporter.script

        XCTAssertTrue(script.contains("unhandledrejection"))
        XCTAssertTrue(script.contains("resource_error"))
        XCTAssertTrue(script.contains("securitypolicyviolation"))
        XCTAssertTrue(script.contains("webview_unclean_restart"))
        XCTAssertTrue(script.contains("reportWebViewError"))
    }

    func makeDelayConditionsJSON() throws -> String {
        let conditions = [
            ["kind": "kill", "value": ""],
            ["kind": "background", "value": "5000"]
        ]
        let data = try JSONSerialization.data(withJSONObject: conditions)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    // MARK: - BundleInfo Tests

    func testBundleInfoInitialization() {
        let bundleInfo = BundleInfo(
            id: "test-id",
            version: "1.0.0",
            status: .PENDING,
            downloaded: Date(),
            checksum: "abc123"
        )

        XCTAssertEqual(bundleInfo.getId(), "test-id")
        XCTAssertEqual(bundleInfo.getVersionName(), "1.0.0")
        XCTAssertEqual(bundleInfo.getStatus(), "pending")
        XCTAssertEqual(bundleInfo.getChecksum(), "abc123")
    }

    func testBundleInfoBuiltin() {
        let bundleInfo = BundleInfo(
            id: BundleInfo.idBuiltin,
            version: "1.0.0",
            status: .SUCCESS,
            downloaded: BundleInfo.downloadedBuiltin,
            checksum: "abc123"
        )

        XCTAssertTrue(bundleInfo.isBuiltin())
        XCTAssertFalse(bundleInfo.isUnknown())
    }

    func testBundleInfoUnknown() {
        let bundleInfo = BundleInfo(
            id: BundleInfo.versionUnknown,
            version: "1.0.0",
            status: .SUCCESS,
            downloaded: BundleInfo.downloadedBuiltin,
            checksum: "abc123"
        )

        XCTAssertTrue(bundleInfo.isUnknown())
        XCTAssertFalse(bundleInfo.isBuiltin())
    }

    func testBundleInfoErrorStatus() {
        let bundleInfo = BundleInfo(
            id: "test-id",
            version: "1.0.0",
            status: .ERROR,
            downloaded: Date(),
            checksum: "abc123"
        )

        XCTAssertTrue(bundleInfo.isErrorStatus())
        XCTAssertFalse(bundleInfo.isDeleted())
    }

    func testBundleInfoDeletedStatus() {
        let bundleInfo = BundleInfo(
            id: "test-id",
            version: "1.0.0",
            status: .DELETED,
            downloaded: Date(),
            checksum: "abc123"
        )

        XCTAssertTrue(bundleInfo.isDeleted())
        XCTAssertFalse(bundleInfo.isErrorStatus())
    }

    func testBuildUserAgentStripsNonIsoCharacters() {
        let ua = CapgoUpdater.buildUserAgent(appId: "com.example.Тест", pluginVersion: "1.2.3🔥", versionOs: "18 😊")
        XCTAssertEqual(ua, "CapacitorUpdater/1.2.3 (com.example.) ios/18")
    }

    func testBuildUserAgentFallsBackToUnknown() {
        let ua = CapgoUpdater.buildUserAgent(appId: "", pluginVersion: "", versionOs: "")
        XCTAssertEqual(ua, "CapacitorUpdater/unknown (unknown) ios/unknown")
    }

    func testBundleInfoEncodeDecode() throws {
        let originalBundle = BundleInfo(
            id: "test-id",
            version: "1.0.0",
            status: .SUCCESS,
            downloaded: Date(),
            checksum: "abc123"
        )

        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(originalBundle)

        // Decode
        let decoder = JSONDecoder()
        let decodedBundle = try decoder.decode(BundleInfo.self, from: data)

        XCTAssertEqual(decodedBundle.getId(), originalBundle.getId())
        XCTAssertEqual(decodedBundle.getVersionName(), originalBundle.getVersionName())
        XCTAssertEqual(decodedBundle.getStatus(), originalBundle.getStatus())
        XCTAssertEqual(decodedBundle.getChecksum(), originalBundle.getChecksum())
    }

    func testShouldResetForForeignBundleWhenPathIsSetButBundleIsNotStored() {
        XCTAssertTrue(CapgoUpdater.shouldResetForForeignBundle(
            bundlePath: "/data/user/0/app/files/versions/abc123",
            isBuiltin: false,
            hasStoredBundleInfo: false
        ))
    }

    func testShouldNotResetForForeignBundleWhenBundleIsBuiltin() {
        XCTAssertFalse(CapgoUpdater.shouldResetForForeignBundle(
            bundlePath: "public",
            isBuiltin: true,
            hasStoredBundleInfo: false
        ))
    }

    func testShouldNotResetForForeignBundleWhenBundleIsStored() {
        XCTAssertFalse(CapgoUpdater.shouldResetForForeignBundle(
            bundlePath: "/data/user/0/app/files/versions/abc123",
            isBuiltin: false,
            hasStoredBundleInfo: true
        ))
    }

    // MARK: - BundleStatus Tests

    func testBundleStatusLocalization() {
        XCTAssertEqual(BundleStatus.SUCCESS.localizedString, "success")
        XCTAssertEqual(BundleStatus.ERROR.localizedString, "error")
        XCTAssertEqual(BundleStatus.PENDING.localizedString, "pending")
        XCTAssertEqual(BundleStatus.DELETED.localizedString, "deleted")
        XCTAssertEqual(BundleStatus.DOWNLOADING.localizedString, "downloading")
    }

    func testBundleStatusStoredValue() {
        XCTAssertEqual(BundleStatus.SUCCESS.storedValue, "success")
        XCTAssertEqual(BundleStatus.ERROR.storedValue, "error")
        XCTAssertEqual(BundleStatus.PENDING.storedValue, "pending")
        XCTAssertEqual(BundleStatus.DELETED.storedValue, "deleted")
        XCTAssertEqual(BundleStatus.DOWNLOADING.storedValue, "downloading")
    }

    func testBundleStatusFromLocalizedString() {
        XCTAssertEqual(BundleStatus(localizedString: "success"), BundleStatus.SUCCESS)
        XCTAssertEqual(BundleStatus(localizedString: "error"), BundleStatus.ERROR)
        XCTAssertEqual(BundleStatus(localizedString: "pending"), BundleStatus.PENDING)
        XCTAssertEqual(BundleStatus(localizedString: "deleted"), BundleStatus.DELETED)
        XCTAssertEqual(BundleStatus(localizedString: "downloading"), BundleStatus.DOWNLOADING)
        XCTAssertNil(BundleStatus(localizedString: "invalid"))
    }

    func testBundleStatusEncodesStableStoredValue() throws {
        let data = try JSONEncoder().encode(BundleStatus.SUCCESS)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"success\"")
    }

    func testBundleStatusDecodesLegacyCaseKeyObject() throws {
        let data = try XCTUnwrap("""
        {"SUCCESS":{}}
        """.data(using: .utf8))

        let decoded = try JSONDecoder().decode(BundleStatus.self, from: data)

        XCTAssertEqual(decoded, .SUCCESS)
    }

    func testBundleInfoDecodesLegacyBundleStatusObject() throws {
        let data = try XCTUnwrap("""
        {"downloaded":"1970-01-01T00:00:00.000Z","id":"test-id","version":"1.0.0","checksum":"abc123","status":{"SUCCESS":{}}}
        """.data(using: .utf8))

        let decodedBundle = try JSONDecoder().decode(BundleInfo.self, from: data)

        XCTAssertEqual(decodedBundle.getId(), "test-id")
        XCTAssertEqual(decodedBundle.getVersionName(), "1.0.0")
        XCTAssertEqual(decodedBundle.getChecksum(), "abc123")
        XCTAssertEqual(decodedBundle.getStatus(), BundleStatus.SUCCESS.storedValue)
    }

    func testSetChannelRejectsNonSuccessStatusWithoutPersistingDefaultChannel() throws {
        let updater = ChannelRequestCapgoUpdater()
        updater.setLogger(Logger(withTag: "TestLogger"))
        updater.channelUrl = "https://example.com/channel"
        updater.defaultChannel = "stable"

        let channelURL = try XCTUnwrap(URL(string: "https://example.com/channel"))
        let response = try XCTUnwrap(HTTPURLResponse(url: channelURL, statusCode: 401, httpVersion: nil, headerFields: nil))
        let responseData = try XCTUnwrap("""
        {"status":"error","message":"Unauthorized"}
        """.data(using: .utf8))
        updater.requestResult = CapgoUpdater.RequestResult(data: responseData, response: response, error: nil, timedOut: false)

        let defaultsKey = "CapacitorUpdaterTests.defaultChannel.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }

        let result = updater.setChannel(channel: "beta", defaultChannelKey: defaultsKey, allowSetDefaultChannel: true)

        XCTAssertEqual(result.error, "response_error")
        XCTAssertEqual(result.message, "Unauthorized")
        XCTAssertEqual(updater.defaultChannel, "stable")
        XCTAssertNil(UserDefaults.standard.string(forKey: defaultsKey))
    }

    // MARK: - DelayCondition Tests

    func testDelayConditionInitialization() {
        let condition = DelayCondition(kind: .background, value: "test-value")

        XCTAssertEqual(condition.getKind(), "background")
        XCTAssertEqual(condition.getValue(), "test-value")
    }

    func testDelayConditionWithStringInit() {
        let condition = DelayCondition(kind: "kill", value: "test-value")

        XCTAssertEqual(condition.getKind(), "kill")
        XCTAssertEqual(condition.getValue(), "test-value")
    }

    func testDelayConditionToJSON() {
        let condition = DelayCondition(kind: .nativeVersion, value: "1.0.0")
        let json = condition.toJSON()

        XCTAssertEqual(json["kind"], "nativeVersion")
        XCTAssertEqual(json["value"], "1.0.0")
    }

    func testDelayConditionEquality() {
        let condition1 = DelayCondition(kind: .date, value: "2023-01-01")
        let condition2 = DelayCondition(kind: .date, value: "2023-01-01")
        let condition3 = DelayCondition(kind: .date, value: "2023-01-02")

        XCTAssertTrue(condition1 == condition2)
        XCTAssertFalse(condition1 == condition3)
    }

}
