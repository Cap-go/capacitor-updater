import XCTest
@testable import CapacitorUpdaterPlugin
import Capacitor
import Version

extension CapacitorUpdaterTests {
    func testDirectUpdatePrecheckDoesNotConsumeAtInstallState() {
        plugin.configureDirectUpdateModeForTesting("atInstall")
        plugin.wasRecentlyInstalledOrUpdated = true

        XCTAssertTrue(plugin.canUseDirectUpdateWithoutConsumingState())
        XCTAssertTrue(plugin.wasRecentlyInstalledOrUpdated)
    }

    func testOnLaunchCompletionConsumesWindowAfterFirstCycle() {
        let current = BundleInfo(
            id: "test-id",
            version: "1.0.0",
            status: .SUCCESS,
            downloaded: Date(),
            checksum: "abc123"
        )

        plugin.configureDirectUpdateModeForTesting("onLaunch")

        XCTAssertTrue(plugin.shouldUseDirectUpdateForTesting())
        XCTAssertFalse(plugin.hasConsumedOnLaunchDirectUpdateForTesting)

        plugin.endBackGroundTaskWithNotif(
            msg: "No need to update",
            latestVersionName: current.getVersionName(),
            current: current,
            error: false,
            plannedDirectUpdate: true
        )

        XCTAssertTrue(plugin.hasConsumedOnLaunchDirectUpdateForTesting)
        XCTAssertFalse(plugin.shouldUseDirectUpdateForTesting())
    }

    func testOnLaunchFreshDownloadConsumesWindowBeforeDownloadStarts() {
        let downloadStarted = expectation(description: "fresh download started")
        let current = BundleInfo(
            id: "test-id",
            version: "1.0.0",
            status: .SUCCESS,
            downloaded: Date(),
            checksum: "abc123"
        )
        let latest = AppVersion()
        latest.version = "2.0.0"
        latest.url = "https://example.com/update.zip"

        let freshDownloadImplementation = FreshDownloadCapgoUpdater()
        freshDownloadImplementation.currentBundleValue = current
        freshDownloadImplementation.latestResponse = latest

        plugin = TestableCapacitorUpdaterPlugin()
        plugin.implementation = freshDownloadImplementation
        plugin.configureDirectUpdateModeForTesting("onLaunch")
        plugin.setUpdateUrlForTesting("https://example.com/channel")

        XCTAssertTrue(plugin.shouldUseDirectUpdateForTesting())
        XCTAssertFalse(plugin.hasConsumedOnLaunchDirectUpdateForTesting)

        var consumedWhenDownloadStarted = false
        freshDownloadImplementation.onDownloadStart = {
            consumedWhenDownloadStarted = self.plugin.hasConsumedOnLaunchDirectUpdateForTesting
            downloadStarted.fulfill()
        }

        plugin.backgroundDownload()

        wait(for: [downloadStarted], timeout: 5.0)
        XCTAssertTrue(consumedWhenDownloadStarted)
        XCTAssertTrue(plugin.hasConsumedOnLaunchDirectUpdateForTesting)
        XCTAssertFalse(plugin.shouldUseDirectUpdateForTesting())
    }

    func testOnlyDownloadModeDownloadsWithoutSettingNextBundle() {
        let (testPlugin, freshDownloadImplementation) = makeOnlyDownloadPlugin(downloaded: makeOnlyDownloadBundle())

        XCTAssertFalse(testPlugin.shouldUseDirectUpdateForTesting())

        testPlugin.backgroundDownload()

        assertOnlyDownloadLeavesUpdateManual(plugin: testPlugin, implementation: freshDownloadImplementation)
    }

    func testOnlyDownloadModeDoesNotSetExistingDownloadedBundleNext() {
        let (testPlugin, freshDownloadImplementation) = makeOnlyDownloadPlugin(existing: makeOnlyDownloadBundle())

        testPlugin.backgroundDownload()

        assertOnlyDownloadLeavesUpdateManual(plugin: testPlugin, implementation: freshDownloadImplementation)
    }

    func testOnlyDownloadModeBuiltinNotifiesUpdateAvailableWithoutSettingNextBundle() {
        let (testPlugin, freshDownloadImplementation) = makeOnlyDownloadPlugin()
        let latest = AppVersion()
        latest.version = "builtin"
        freshDownloadImplementation.latestResponse = latest

        testPlugin.backgroundDownload()

        assertOnlyDownloadLeavesUpdateManual(plugin: testPlugin, implementation: freshDownloadImplementation)
        let updateBundle = testPlugin.notifiedEventPayloads["updateAvailable"]?["bundle"] as? [String: String]
        XCTAssertEqual(updateBundle?["id"], BundleInfo.idBuiltin)
    }

    func testOnlyDownloadModeBuiltinDoesNotNotifyWhenBuiltinIsCurrent() {
        let current = BundleInfo(
            id: BundleInfo.idBuiltin,
            version: "builtin",
            status: .SUCCESS,
            downloaded: BundleInfo.downloadedBuiltin,
            checksum: "builtin"
        )
        let (testPlugin, freshDownloadImplementation) = makeOnlyDownloadPlugin(current: current)
        let latest = AppVersion()
        latest.version = "builtin"
        freshDownloadImplementation.latestResponse = latest

        testPlugin.backgroundDownload()

        XCTAssertFalse(testPlugin.notifiedEventNames.contains("updateAvailable"))
        XCTAssertTrue(testPlugin.notifiedEventNames.contains("noNeedUpdate"))
        XCTAssertEqual(freshDownloadImplementation.setNextBundleCalls, 0)
    }

    func testNoNewVersionAvailableDoesNotNotifyDownloadFailed() {
        let current = BundleInfo(
            id: "test-id",
            version: "1.0.0",
            status: .SUCCESS,
            downloaded: Date(),
            checksum: "abc123"
        )
        let latest = AppVersion()
        latest.error = "no_new_version_available"
        latest.kind = "up_to_date"
        latest.message = "No new version available"
        latest.statusCode = 200

        let noUpdateImplementation = FreshDownloadCapgoUpdater()
        noUpdateImplementation.currentBundleValue = current
        noUpdateImplementation.latestResponse = latest

        let testPlugin = TestableCapacitorUpdaterPlugin()
        testPlugin.implementation = noUpdateImplementation
        testPlugin.setUpdateUrlForTesting("https://example.com/channel")

        testPlugin.backgroundDownload()

        XCTAssertTrue(testPlugin.notifiedEventNames.contains("noNeedUpdate"))
        XCTAssertTrue(testPlugin.notifiedEventNames.contains("updateCheckResult"))
        XCTAssertFalse(testPlugin.notifiedEventNames.contains("downloadFailed"))
        XCTAssertFalse(noUpdateImplementation.sentStatsActions.contains("download_fail"))
    }

    func testGetLatestRejectsLegacyErrorWithoutBackendKind() throws {
        let latest = AppVersion()
        latest.error = "no_new_version_available"
        latest.message = "No new version available"
        latest.statusCode = 200

        let noUpdateImplementation = FreshDownloadCapgoUpdater()
        noUpdateImplementation.latestResponse = latest

        let testPlugin = TestableCapacitorUpdaterPlugin()
        testPlugin.implementation = noUpdateImplementation
        testPlugin.setUpdateUrlForTesting("https://example.com/channel")

        let rejected = expectation(description: "getLatest rejects legacy response without kind")
        let call = try XCTUnwrap(CAPPluginCall(
            callbackId: "get-latest-legacy-error-test",
            options: [:],
            success: { _, _ in
                XCTFail("getLatest should reject legacy error responses without backend kind")
            },
            error: { error in
                XCTAssertEqual(error?.message, "no_new_version_available")
                rejected.fulfill()
            }
        ))

        testPlugin.getLatest(call)
        wait(for: [rejected], timeout: 10)
    }

    func testGetLatestRejectsFailedKindWithoutErrorMessage() throws {
        let latest = AppVersion()
        latest.kind = "failed"
        latest.statusCode = 500

        let failedImplementation = FreshDownloadCapgoUpdater()
        failedImplementation.latestResponse = latest

        let testPlugin = TestableCapacitorUpdaterPlugin()
        testPlugin.implementation = failedImplementation
        testPlugin.setUpdateUrlForTesting("https://example.com/channel")

        let rejected = expectation(description: "getLatest rejects failed kind")
        let call = try XCTUnwrap(CAPPluginCall(
            callbackId: "get-latest-failed-kind-test",
            options: [:],
            success: { _, _ in
                XCTFail("getLatest should reject failed kind responses")
            },
            error: { error in
                XCTAssertEqual(error?.message, "server did not provide a message")
                rejected.fulfill()
            }
        ))

        testPlugin.getLatest(call)
        wait(for: [rejected], timeout: 10)
    }

    func testGetLatestRejectsFailedErrorUsingBackendErrorCode() throws {
        let latest = AppVersion()
        latest.error = "response_error"
        latest.message = "Server returned an invalid response"
        latest.kind = "failed"
        latest.statusCode = 500

        let failedImplementation = FreshDownloadCapgoUpdater()
        failedImplementation.latestResponse = latest

        let testPlugin = TestableCapacitorUpdaterPlugin()
        testPlugin.implementation = failedImplementation
        testPlugin.setUpdateUrlForTesting("https://example.com/channel")

        let rejected = expectation(description: "getLatest rejects failed error")
        let call = try XCTUnwrap(CAPPluginCall(
            callbackId: "get-latest-failed-error-test",
            options: [:],
            success: { _, _ in
                XCTFail("getLatest should reject failed error responses")
            },
            error: { error in
                XCTAssertEqual(error?.message, "response_error")
                rejected.fulfill()
            }
        ))

        testPlugin.getLatest(call)
        wait(for: [rejected], timeout: 10)
    }

    func testGetLatestBreakingResponseNotifiesBreakingListeners() throws {
        let latest = AppVersion()
        latest.version = "2.0.0"
        latest.breaking = true
        latest.message = "store_update_required"
        latest.statusCode = 200

        let breakingImplementation = FreshDownloadCapgoUpdater()
        breakingImplementation.latestResponse = latest

        let testPlugin = TestableCapacitorUpdaterPlugin()
        testPlugin.implementation = breakingImplementation
        testPlugin.setUpdateUrlForTesting("https://example.com/channel")

        let rejected = expectation(description: "getLatest rejects store update response")
        let call = try XCTUnwrap(CAPPluginCall(
            callbackId: "get-latest-breaking-response-test",
            options: [:],
            success: { _, _ in
                XCTFail("getLatest should reject store update responses")
            },
            error: { error in
                XCTAssertEqual(error?.message, "store_update_required")
                rejected.fulfill()
            }
        ))

        testPlugin.getLatest(call)
        wait(for: [rejected], timeout: 10)

        XCTAssertTrue(testPlugin.notifiedEventNames.contains("breakingAvailable"))
        XCTAssertTrue(testPlugin.notifiedEventNames.contains("majorAvailable"))
        XCTAssertEqual(testPlugin.notifiedEventPayloads["breakingAvailable"]?["version"] as? String, "2.0.0")
        XCTAssertEqual(testPlugin.notifiedEventPayloads["majorAvailable"]?["version"] as? String, "2.0.0")
    }

    func testGetLatestBreakingResponseWithoutVersionNotifiesCurrentBundleVersion() throws {
        let current = BundleInfo(
            id: "test-id",
            version: "1.0.0",
            status: .SUCCESS,
            downloaded: Date(),
            checksum: "abc123"
        )
        let latest = AppVersion()
        latest.error = "disable_auto_update_to_major"
        latest.kind = "blocked"
        latest.message = "Cannot upgrade major version"
        latest.statusCode = 200

        let breakingImplementation = FreshDownloadCapgoUpdater()
        breakingImplementation.currentBundleValue = current
        breakingImplementation.latestResponse = latest

        let testPlugin = TestableCapacitorUpdaterPlugin()
        testPlugin.implementation = breakingImplementation
        testPlugin.setUpdateUrlForTesting("https://example.com/channel")

        let resolved = expectation(description: "getLatest resolves blocked breaking response")
        let call = try XCTUnwrap(CAPPluginCall(
            callbackId: "get-latest-breaking-response-no-version-test",
            options: [:],
            success: { _, _ in
                resolved.fulfill()
            },
            error: { _ in
                XCTFail("getLatest should resolve blocked breaking responses")
            }
        ))

        testPlugin.getLatest(call)
        wait(for: [resolved], timeout: 10)

        XCTAssertTrue(testPlugin.notifiedEventNames.contains("breakingAvailable"))
        XCTAssertTrue(testPlugin.notifiedEventNames.contains("majorAvailable"))
        XCTAssertEqual(testPlugin.notifiedEventPayloads["breakingAvailable"]?["version"] as? String, "1.0.0")
        XCTAssertEqual(testPlugin.notifiedEventPayloads["majorAvailable"]?["version"] as? String, "1.0.0")
    }

}
