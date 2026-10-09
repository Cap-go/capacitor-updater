import XCTest
@testable import CapacitorUpdaterPlugin
import Capacitor

private final class LifecycleCapgoUpdater: CapgoUpdater {
    var currentBundleValue = BundleInfo(id: "current-id", version: "1.0.0", status: .SUCCESS, downloaded: Date(), checksum: "abc")
    var nextBundleValue: BundleInfo?
    var downloadedBundleValue: BundleInfo?
    var latestResponse = AppVersion()
    var getLatestCalls = 0
    var downloadCalls = 0
    var setErrorCalls = 0
    private let statsLock = NSLock()
    private var sentStats: [String] = []

    func statCount(_ action: String) -> Int {
        statsLock.lock()
        defer { statsLock.unlock() }
        return sentStats.filter { $0 == action }.count
    }

    private func record(_ action: String) {
        statsLock.lock()
        sentStats.append(action)
        statsLock.unlock()
    }

    override func getLatest(url: URL, channel: String?, appIdOverride: String? = nil) -> AppVersion {
        getLatestCalls += 1
        return latestResponse
    }

    override func getCurrentBundle() -> BundleInfo {
        currentBundleValue
    }

    override func getNextBundle() -> BundleInfo? {
        nextBundleValue
    }

    override func setNextBundle(next: String?) -> Bool {
        if next == nil {
            nextBundleValue = nil
        }
        return true
    }

    override func getBundleInfo(id: String?) -> BundleInfo {
        currentBundleValue
    }

    override func getBundleInfoByVersionName(version: String) -> BundleInfo? {
        nil
    }

    override func download(url: URL, version: String, sessionKey: String, link: String? = nil, comment: String? = nil) throws -> BundleInfo {
        try downloadVerified(
            url: url,
            version: version,
            sessionKey: sessionKey,
            expectedChecksum: "",
            link: link,
            comment: comment
        )
    }

    override func downloadVerified(
        url _: URL,
        version _: String,
        sessionKey _: String,
        expectedChecksum _: String,
        link _: String? = nil,
        comment _: String? = nil
    ) throws -> BundleInfo {
        downloadCalls += 1
        guard let downloadedBundleValue else {
            throw NSError(domain: "UpdateLifecycleTests", code: 1)
        }
        return downloadedBundleValue
    }

    override func setError(bundle: BundleInfo) {
        setErrorCalls += 1
        currentBundleValue = bundle.setStatus(status: BundleStatus.ERROR.storedValue)
    }

    override func saveBundleInfo(id: String, bundle: BundleInfo?) -> Bool {
        true
    }

    override func delete(id: String, removeInfo: Bool) -> Bool {
        true
    }

    override func persistPendingStats() {}

    override func sendStats(action: String, versionName: String? = nil, oldVersionName: String? = "") {
        record(action)
    }

    override func sendStats(action: String, versionName: String?, oldVersionName: String?, metadata: [String: String]) {
        record(action)
    }

    override func sendStats(action: String, versionName: String?, oldVersionName: String?, metadata: [String: String], onSent: @escaping () -> Void) {
        record(action)
    }
}

private final class LifecyclePlugin: CapacitorUpdaterPlugin {
    private(set) var events: [String] = []
    private(set) var payloads: [String: [String: Any]] = [:]
    private(set) var readyMessages: [String] = []

    override func notifyListeners(_ eventName: String, data: [String: Any]?, retainUntilConsumed retain: Bool) {
        events.append(eventName)
        if let data {
            payloads[eventName] = data
        }
    }

    override func endBackGroundTask() {}

    override func runBackgroundDownloadWork(_ work: @escaping () -> Void) {
        work()
    }

    override func runGetLatestWork(_ work: @escaping () -> Void) {
        work()
    }

    override func sendReadyToJs(current: BundleInfo, msg: String) {
        readyMessages.append(msg)
    }
}

final class UpdateLifecycleTests: XCTestCase {
    private var plugin = LifecyclePlugin()
    private var updater = LifecycleCapgoUpdater()
    private let delayPreferencesKey = DelayUpdateUtils.DELAY_CONDITION_PREFERENCES
    private let delayConditionModeKey = DelayUpdateUtils.DELAY_CONDITION_MODE_PREFERENCES
    private let updateUrl = URL(string: "https://example.com/updates")!
    private let lastFailedBundleKey = "CapacitorUpdater.lastFailedBundle"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let testLogger = Logger(withTag: "UpdateLifecycleTests", options: Logger.Options(level: .silent))
        CryptoCipher.setLogger(testLogger)
        updater = LifecycleCapgoUpdater()
        updater.setLogger(testLogger)
        plugin = LifecyclePlugin()
        plugin.implementation = updater
        plugin.setUpdateUrlForTesting(updateUrl.absoluteString)
        plugin.setDelayUpdateUtilsForTesting(
            DelayUpdateUtils(currentVersionNative: try CapgoSemanticVersion("1.0.0"), logger: Logger(withTag: "UpdateLifecycleTests"))
        )
        UserDefaults.standard.removeObject(forKey: delayPreferencesKey)
        UserDefaults.standard.removeObject(forKey: delayConditionModeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: delayPreferencesKey)
        UserDefaults.standard.removeObject(forKey: delayConditionModeKey)
        UserDefaults.standard.removeObject(forKey: lastFailedBundleKey)
        super.tearDown()
    }

    private func pendingBundle() -> BundleInfo {
        BundleInfo(id: "bundle-2", version: "2.0.0", status: .PENDING, downloaded: Date(), checksum: "abc")
    }

    private func latest(version: String) -> AppVersion {
        let latest = AppVersion()
        latest.version = version
        latest.url = "https://example.com/update.zip"
        latest.checksum = "abc"
        return latest
    }

    private func spinMainRunLoop(seconds: TimeInterval) {
        let done = expectation(description: "main run loop")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            done.fulfill()
        }
        wait(for: [done], timeout: seconds + 5)
    }

    // set() activated the pending next bundle but left it stored, so getNextBundle() kept
    // returning the bundle that was already running.
    func testClearNextBundleIfCurrentDropsTheRunningBundle() {
        updater.currentBundleValue = pendingBundle()
        updater.nextBundleValue = pendingBundle()

        XCTAssertTrue(updater.clearNextBundleIfCurrent())
        XCTAssertNil(updater.nextBundleValue)
    }

    func testClearNextBundleIfCurrentKeepsADifferentNextBundle() {
        updater.nextBundleValue = pendingBundle()

        XCTAssertFalse(updater.clearNextBundleIfCurrent())
        XCTAssertEqual(updater.nextBundleValue?.getId(), "bundle-2")
    }

    // A suspended app can resume with the rollback timer already expired, before
    // willEnterForeground re-arms it: the bundle must not be rolled back in background.
    func testRollbackCheckWaitsForTheNextForegroundWhileInBackground() {
        updater.currentBundleValue = pendingBundle()
        plugin.setAppReadyTimeoutForTesting(10)

        plugin.appMovedToBackground()
        plugin.DeferredNotifyAppReadyCheck()

        XCTAssertFalse(plugin.events.contains("updateFailed"))
        XCTAssertEqual(updater.setErrorCalls, 0)

        // The next foreground arms a fresh check, which rolls back a page that never confirmed.
        plugin.appMovedToForeground()
        spinMainRunLoop(seconds: 0.5)

        XCTAssertTrue(plugin.events.contains("updateFailed"))
        XCTAssertEqual(updater.setErrorCalls, 1)
    }

    func testRollbackCheckStillRunsInForeground() {
        updater.currentBundleValue = pendingBundle()

        plugin.DeferredNotifyAppReadyCheck()

        XCTAssertTrue(plugin.events.contains("updateFailed"))
        XCTAssertEqual(updater.setErrorCalls, 1)
    }

    // app_launch_timeout used to be sent on every rollback of the launch.
    func testLaunchTimeoutIsReportedOncePerLaunch() {
        updater.statsUrl = "https://stats.example.com"
        updater.currentBundleValue = pendingBundle()
        plugin.checkRevert()
        updater.currentBundleValue = BundleInfo(id: "bundle-3", version: "3.0.0", status: .PENDING, downloaded: Date(), checksum: "abc")
        plugin.checkRevert()

        XCTAssertEqual(updater.statCount("update_fail"), 2)
        XCTAssertEqual(updater.statCount("app_launch_timeout"), 1)
    }

    // The periodic check used to download on error responses (empty version != current).
    func testPeriodicCheckReportsErrorResponsesWithoutDownloading() {
        plugin.setAutoUpdateModeForTesting("atBackground")
        let response = AppVersion()
        response.error = "no_new_version_available"
        response.kind = "up_to_date"
        response.message = "No new version available"
        updater.latestResponse = response

        plugin.runPeriodicUpdateCheck(url: updateUrl)

        XCTAssertEqual(updater.getLatestCalls, 1)
        XCTAssertEqual(plugin.payloads["updateCheckResult"]?["kind"] as? String, "up_to_date")
        XCTAssertFalse(plugin.events.contains("downloadFailed"))
    }

    func testPeriodicCheckDoesNotDownloadTheCurrentVersion() {
        plugin.setAutoUpdateModeForTesting("atBackground")
        updater.latestResponse = latest(version: "1.0.0")

        plugin.runPeriodicUpdateCheck(url: updateUrl)

        XCTAssertEqual(updater.getLatestCalls, 1)
        XCTAssertFalse(plugin.events.contains("updateCheckResult"))
    }

    func testPeriodicCheckDownloadsANewVersion() {
        plugin.setAutoUpdateModeForTesting("atBackground")
        updater.latestResponse = latest(version: "2.0.0")

        plugin.runPeriodicUpdateCheck(url: updateUrl)

        XCTAssertEqual(updater.getLatestCalls, 2)
        XCTAssertEqual(updater.downloadCalls, 1)
    }

    // triggerUpdateCheck returned "preview_session" (not in the TS union) and never "unavailable".
    func testTriggerUpdateCheckIsUnavailableWhenAutoUpdateIsDisabled() {
        XCTAssertEqual(plugin.triggerBackgroundUpdateCheck(), "unavailable")
        XCTAssertEqual(updater.getLatestCalls, 0)
    }

    func testTriggerUpdateCheckIsUnavailableDuringAPreviewSession() {
        plugin.setAutoUpdateModeForTesting("atBackground")
        plugin.previewSessionEnabled = true

        XCTAssertEqual(plugin.triggerBackgroundUpdateCheck(), "unavailable")
        XCTAssertEqual(updater.getLatestCalls, 0)
    }

    func testTriggerUpdateCheckQueuesWhenAutoUpdateIsEnabled() {
        plugin.setAutoUpdateModeForTesting("atBackground")
        updater.latestResponse = latest(version: "1.0.0")

        XCTAssertEqual(plugin.triggerBackgroundUpdateCheck(), "queued")
        XCTAssertEqual(updater.getLatestCalls, 1)
    }

    // Malformed stored delay conditions used to crash on `kind as! String`.
    func testParseDelayConditionsDropsMalformedEntries() {
        let json = #"[{"value":"1"},{"kind":1},"text",3,{"kind":"kill","value":""},{"kind":"background"}]"#

        let conditions = DelayUpdateUtils.parseDelayConditions(json: json)

        XCTAssertEqual(conditions.map { $0.getKind() }, ["kill", "background"])
        XCTAssertTrue(DelayUpdateUtils.parseDelayConditions(json: "not json").isEmpty)
        XCTAssertTrue(DelayUpdateUtils.parseDelayConditions(json: #"{"kind":"kill"}"#).isEmpty)
    }

    func testCheckCancelDelaySurvivesMalformedStoredConditions() throws {
        UserDefaults.standard.set(#"[1,{"value":"1"},{"kind":"kill","value":""}]"#, forKey: delayPreferencesKey)

        plugin.appMovedToBackground()

        let stored = try XCTUnwrap(UserDefaults.standard.string(forKey: delayPreferencesKey))
        XCTAssertEqual(DelayUpdateUtils.parseDelayConditions(json: stored).map { $0.getKind() }, ["kill"])
    }

    func testDirectUpdateSurvivesMalformedStoredConditions() {
        plugin.configureDirectUpdateModeForTesting("always")
        updater.latestResponse = latest(version: "2.0.0")
        updater.downloadedBundleValue = pendingBundle()
        UserDefaults.standard.set(#"[{"value":"1"},{"kind":"kill","value":""}]"#, forKey: delayPreferencesKey)

        plugin.backgroundDownload()

        XCTAssertEqual(updater.downloadCalls, 1)
        XCTAssertEqual(plugin.readyMessages, ["Update delayed until delay conditions met"])
    }
}
