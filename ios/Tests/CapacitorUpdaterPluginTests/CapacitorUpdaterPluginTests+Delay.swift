import XCTest
@testable import CapacitorUpdaterPlugin
import Capacitor
import Version

extension CapacitorUpdaterTests {
    func testBlockedUpdateCheckDoesNotNotifyDownloadFailed() {
        let current = BundleInfo(
            id: "test-id",
            version: "1.0.0",
            status: .SUCCESS,
            downloaded: Date(),
            checksum: "abc123"
        )
        let latest = AppVersion()
        latest.version = "2.0.0"
        latest.error = "disable_auto_update_to_major"
        latest.kind = "blocked"
        latest.message = "Cannot upgrade major version"
        latest.statusCode = 200

        let blockedImplementation = FreshDownloadCapgoUpdater()
        blockedImplementation.currentBundleValue = current
        blockedImplementation.latestResponse = latest

        let testPlugin = TestableCapacitorUpdaterPlugin()
        testPlugin.implementation = blockedImplementation
        testPlugin.setUpdateUrlForTesting("https://example.com/channel")

        testPlugin.backgroundDownload()

        XCTAssertTrue(testPlugin.notifiedEventNames.contains("noNeedUpdate"))
        XCTAssertTrue(testPlugin.notifiedEventNames.contains("updateCheckResult"))
        XCTAssertTrue(testPlugin.notifiedEventNames.contains("breakingAvailable"))
        XCTAssertTrue(testPlugin.notifiedEventNames.contains("majorAvailable"))
        XCTAssertEqual(testPlugin.notifiedEventPayloads["breakingAvailable"]?["version"] as? String, "2.0.0")
        XCTAssertEqual(testPlugin.notifiedEventPayloads["majorAvailable"]?["version"] as? String, "2.0.0")
        XCTAssertFalse(testPlugin.notifiedEventNames.contains("downloadFailed"))
        XCTAssertFalse(blockedImplementation.sentStatsActions.contains("download_fail"))
    }

    func testBreakingNoUrlUpdateCheckNotifiesBreakingListeners() {
        let current = BundleInfo(
            id: "test-id",
            version: "1.0.0",
            status: .SUCCESS,
            downloaded: Date(),
            checksum: "abc123"
        )
        let latest = AppVersion()
        latest.version = "2.0.0"
        latest.breaking = true
        latest.message = "store_update_required"
        latest.statusCode = 200

        let breakingImplementation = FreshDownloadCapgoUpdater()
        breakingImplementation.currentBundleValue = current
        breakingImplementation.latestResponse = latest

        let testPlugin = TestableCapacitorUpdaterPlugin()
        testPlugin.implementation = breakingImplementation
        testPlugin.setUpdateUrlForTesting("https://example.com/channel")

        testPlugin.backgroundDownload()

        XCTAssertTrue(testPlugin.notifiedEventNames.contains("breakingAvailable"))
        XCTAssertTrue(testPlugin.notifiedEventNames.contains("majorAvailable"))
        XCTAssertEqual(testPlugin.notifiedEventPayloads["breakingAvailable"]?["version"] as? String, "2.0.0")
        XCTAssertEqual(testPlugin.notifiedEventPayloads["majorAvailable"]?["version"] as? String, "2.0.0")
        XCTAssertTrue(testPlugin.notifiedEventNames.contains("downloadFailed"))
        XCTAssertTrue(breakingImplementation.sentStatsActions.contains("download_fail"))
    }

    func testFailedUpdateCheckNotifiesDownloadFailed() {
        let current = BundleInfo(
            id: "test-id",
            version: "1.0.0",
            status: .SUCCESS,
            downloaded: Date(),
            checksum: "abc123"
        )
        let latest = AppVersion()
        latest.error = "response_error"
        latest.kind = "failed"
        latest.message = "Error getting Latest"
        latest.statusCode = 500

        let failedImplementation = FreshDownloadCapgoUpdater()
        failedImplementation.currentBundleValue = current
        failedImplementation.latestResponse = latest

        let testPlugin = TestableCapacitorUpdaterPlugin()
        testPlugin.implementation = failedImplementation
        testPlugin.setUpdateUrlForTesting("https://example.com/channel")

        testPlugin.backgroundDownload()

        XCTAssertTrue(testPlugin.notifiedEventNames.contains("updateCheckResult"))
        XCTAssertTrue(testPlugin.notifiedEventNames.contains("downloadFailed"))
        XCTAssertTrue(failedImplementation.sentStatsActions.contains("download_fail"))
    }

    func testHasNativeBuildVersionChangedFallsBackToLegacyStoredKey() {
        let nativeBuildKey = "LatestNativeBuildVersion"
        let legacyBuildKey = "LatestVersionNative"
        UserDefaults.standard.removeObject(forKey: nativeBuildKey)
        UserDefaults.standard.set("1", forKey: legacyBuildKey)
        defer {
            UserDefaults.standard.removeObject(forKey: nativeBuildKey)
            UserDefaults.standard.removeObject(forKey: legacyBuildKey)
        }

        plugin.setCurrentBuildVersionForTesting("2")

        XCTAssertTrue(plugin.hasNativeBuildVersionChanged())
    }

    func testResetCurrentBundleForNativeBuildChangeIfNeededResetsSynchronously() {
        let nativeBuildKey = "LatestNativeBuildVersion"
        let resetPlugin = TestableCapacitorUpdaterPlugin()
        let resetImplementation = ResetTrackingCapgoUpdater()
        resetPlugin.implementation = resetImplementation
        UserDefaults.standard.set("1", forKey: nativeBuildKey)
        defer {
            UserDefaults.standard.removeObject(forKey: nativeBuildKey)
        }

        resetPlugin.setCurrentBuildVersionForTesting("2")

        XCTAssertTrue(resetPlugin.resetCurrentBundleForNativeBuildChangeIfNeeded())
        XCTAssertTrue(resetImplementation.resetCalled)
        XCTAssertTrue(resetImplementation.resetIsInternal)
    }

    func testShowSplashscreenOptionsDisableAutoHide() {
        let options = plugin.splashscreenOptionsForTesting(methodName: "show")

        XCTAssertEqual(options["autoHide"] as? Bool, false)
    }

    func testHideSplashscreenOptionsStayEmpty() {
        let options = plugin.splashscreenOptionsForTesting(methodName: "hide")

        XCTAssertTrue(options.isEmpty)
    }

    func testSplashscreenInvocationTokenRejectsStaleRequests() {
        XCTAssertTrue(plugin.isCurrentSplashscreenInvocationTokenForTesting(0))

        plugin.advanceSplashscreenInvocationTokenForTesting()

        XCTAssertFalse(plugin.isCurrentSplashscreenInvocationTokenForTesting(0))
    }

    func testDelayUpdateUtilsSetMultiDelayStoresMultipleConditions() throws {
        let utils = try makeDelayUpdateUtils()
        clearDelayStorage()
        defer { clearDelayStorage() }
        let json = try makeDelayConditionsJSON()

        XCTAssertTrue(utils.setMultiDelay(delayConditions: json))
        XCTAssertEqual(UserDefaults.standard.string(forKey: delayPreferencesKey), json)
    }

    func testDelayUpdateUtilsCheckCancelDelayKilledKeepsOtherConditions() throws {
        let utils = try makeDelayUpdateUtils()
        clearDelayStorage()
        defer { clearDelayStorage() }
        let json = try makeDelayConditionsJSON()
        XCTAssertTrue(utils.setMultiDelay(delayConditions: json))

        utils.checkCancelDelay(source: .killed)

        let stored = try XCTUnwrap(UserDefaults.standard.string(forKey: delayPreferencesKey))
        let storedData = try XCTUnwrap(stored.data(using: .utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: storedData) as? [[String: String]])

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?["kind"], "background")
        XCTAssertEqual(parsed.first?["value"], "5000")
    }

    // MARK: - DelayUntilNext Tests

}
