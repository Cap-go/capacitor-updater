import XCTest
@testable import CapacitorUpdaterPlugin
import Capacitor
import Version

private class TestableCapacitorUpdaterPlugin: CapacitorUpdaterPlugin {
    override func endBackGroundTask() {
        // Intentionally blank: tests avoid touching UIApplication background-task APIs.
    }

    override func runBackgroundDownloadWork(_ work: @escaping () -> Void) {
        work()
    }

    override func sendReadyToJs(current: BundleInfo, msg: String) {
        // Intentionally blank: tests assert native state transitions without JS bridge side effects.
    }
}

private final class FreshDownloadCapgoUpdater: CapgoUpdater {
    var currentBundleValue: BundleInfo!
    var latestResponse = AppVersion()
    var onDownloadStart: (() -> Void)?

    override func getLatest(url: URL, channel: String?) -> AppVersion {
        latestResponse
    }

    override func getCurrentBundle() -> BundleInfo {
        currentBundleValue
    }

    override func getBundleInfoByVersionName(version: String) -> BundleInfo? {
        nil
    }

    override func download(url: URL, version: String, sessionKey: String, link: String? = nil, comment: String? = nil) throws -> BundleInfo {
        onDownloadStart?()
        throw NSError(domain: "CapacitorUpdaterPluginTests", code: 1)
    }

    override func sendStats(action: String, versionName: String? = nil, oldVersionName: String? = "") {
        // Intentionally blank: test doubles should not emit network-backed stats.
    }
}

private final class ResetTrackingCapgoUpdater: CapgoUpdater {
    let currentBundleValue = BundleInfo(
        id: "current-id",
        version: "1.0.0",
        status: .SUCCESS,
        downloaded: Date(),
        checksum: "abc123"
    )
    var fallbackBundleValue = BundleInfo(
        id: BundleInfo.ID_BUILTIN,
        version: "builtin",
        status: .SUCCESS,
        downloaded: BundleInfo.DOWNLOADED_BUILTIN,
        checksum: "builtin"
    )
    var nextBundleValue: BundleInfo?
    var resetCalled = false
    var prepareResetStateForTransitionCalled = false
    var finalizeResetTransitionCalled = false
    var finalizeResetTransitionPreviousBundleName: String?
    var finalizeResetTransitionIsInternal = true
    var canSetResult = true
    var setResult = true
    var canSetCalls = 0
    var setCalls = 0
    var stagePendingReloadResult = true
    var stagePendingReloadCalls = 0
    var finalizePendingReloadCalls = 0
    var finalizedPendingReloadBundle: BundleInfo?
    var finalizePendingReloadPreviousBundleName: String?
    var restoreResetStateCalls = 0
    let capturedState = ResetState(
        currentBundlePath: "/stored/current",
        fallbackBundleId: "fallback-id",
        nextBundleId: "next-id"
    )
    var restoredState: ResetState?

    override func getCurrentBundle() -> BundleInfo {
        currentBundleValue
    }

    override func getFallbackBundle() -> BundleInfo {
        fallbackBundleValue
    }

    override func getNextBundle() -> BundleInfo? {
        nextBundleValue
    }

    override func canSet(bundle: BundleInfo) -> Bool {
        canSetCalls += 1
        return canSetResult
    }

    override func captureResetState() -> ResetState {
        capturedState
    }

    override func restoreResetState(_ state: ResetState) {
        restoreResetStateCalls += 1
        restoredState = state
    }

    override func set(bundle: BundleInfo) -> Bool {
        setCalls += 1
        return setResult
    }

    override func setNextBundle(next: String?) -> Bool {
        true
    }

    override func stagePendingReload(bundle: BundleInfo) -> Bool {
        stagePendingReloadCalls += 1
        return stagePendingReloadResult
    }

    override func finalizePendingReload(bundle: BundleInfo, previousBundleName: String) {
        finalizePendingReloadCalls += 1
        finalizedPendingReloadBundle = bundle
        finalizePendingReloadPreviousBundleName = previousBundleName
    }

    override func reset(isInternal: Bool) {
        resetCalled = true
    }

    override func prepareResetStateForTransition() {
        prepareResetStateForTransitionCalled = true
    }

    override func finalizeResetTransition(previousBundleName: String, isInternal: Bool) {
        finalizeResetTransitionCalled = true
        finalizeResetTransitionPreviousBundleName = previousBundleName
        finalizeResetTransitionIsInternal = isInternal
    }
}

private final class ResetTestableCapacitorUpdaterPlugin: TestableCapacitorUpdaterPlugin {
    override func canPerformResetTransition() -> Bool {
        true
    }

    override func _reload() -> Bool {
        true
    }
}

private final class ReloadBypassCapacitorUpdaterPlugin: TestableCapacitorUpdaterPlugin {
    override func _reload() -> Bool {
        true
    }
}

private final class ReloadFailureCapacitorUpdaterPlugin: TestableCapacitorUpdaterPlugin {
    var restoreLiveBundleStateAfterFailedReloadCalls = 0

    override func canPerformResetTransition() -> Bool {
        true
    }

    override func _reload() -> Bool {
        false
    }

    override func restoreLiveBundleStateAfterFailedReload() {
        restoreLiveBundleStateAfterFailedReloadCalls += 1
    }
}

class CapacitorUpdaterTests: XCTestCase {

    var plugin: CapacitorUpdaterPlugin!
    var implementation: CapgoUpdater!
    private let delayPreferencesKey = DelayUpdateUtils.DELAY_CONDITION_PREFERENCES
    private let backgroundTimestampKey = DelayUpdateUtils.BACKGROUND_TIMESTAMP_KEY

    override func setUp() {
        super.setUp()
        plugin = TestableCapacitorUpdaterPlugin()
        implementation = CapgoUpdater()
    }

    override func tearDown() {
        plugin = nil
        implementation = nil
        super.tearDown()
    }

    private func makeDelayUpdateUtils() throws -> DelayUpdateUtils {
        let logger = Logger(withTag: "TestLogger")
        let version = try Version("1.0.0")
        return DelayUpdateUtils(currentVersionNative: version, logger: logger)
    }

    private func clearDelayStorage() {
        UserDefaults.standard.removeObject(forKey: delayPreferencesKey)
        UserDefaults.standard.removeObject(forKey: backgroundTimestampKey)
    }

    private func makeDelayConditionsJSON() throws -> String {
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
            id: BundleInfo.ID_BUILTIN,
            version: "1.0.0",
            status: .SUCCESS,
            downloaded: BundleInfo.DOWNLOADED_BUILTIN,
            checksum: "abc123"
        )

        XCTAssertTrue(bundleInfo.isBuiltin())
        XCTAssertFalse(bundleInfo.isUnknown())
    }

    func testBundleInfoUnknown() {
        let bundleInfo = BundleInfo(
            id: BundleInfo.VERSION_UNKNOWN,
            version: "1.0.0",
            status: .SUCCESS,
            downloaded: BundleInfo.DOWNLOADED_BUILTIN,
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

    func testBundleStatusFromLocalizedString() {
        XCTAssertEqual(BundleStatus(localizedString: "success"), BundleStatus.SUCCESS)
        XCTAssertEqual(BundleStatus(localizedString: "error"), BundleStatus.ERROR)
        XCTAssertEqual(BundleStatus(localizedString: "pending"), BundleStatus.PENDING)
        XCTAssertEqual(BundleStatus(localizedString: "deleted"), BundleStatus.DELETED)
        XCTAssertEqual(BundleStatus(localizedString: "downloading"), BundleStatus.DOWNLOADING)
        XCTAssertNil(BundleStatus(localizedString: "invalid"))
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

    func testShouldConsumeOnLaunchDirectUpdateForOnLaunchAttempt() {
        XCTAssertTrue(CapacitorUpdaterPlugin.shouldConsumeOnLaunchDirectUpdate(directUpdateMode: "onLaunch", plannedDirectUpdate: true))
    }

    func testShouldNotConsumeOnLaunchDirectUpdateForNonLaunchAttempt() {
        XCTAssertFalse(CapacitorUpdaterPlugin.shouldConsumeOnLaunchDirectUpdate(directUpdateMode: "onLaunch", plannedDirectUpdate: false))
    }

    func testShouldNotConsumeOnLaunchDirectUpdateForOtherModes() {
        XCTAssertFalse(CapacitorUpdaterPlugin.shouldConsumeOnLaunchDirectUpdate(directUpdateMode: "always", plannedDirectUpdate: true))
        XCTAssertFalse(CapacitorUpdaterPlugin.shouldConsumeOnLaunchDirectUpdate(directUpdateMode: "atInstall", plannedDirectUpdate: true))
        XCTAssertFalse(CapacitorUpdaterPlugin.shouldConsumeOnLaunchDirectUpdate(directUpdateMode: "false", plannedDirectUpdate: true))
    }

    func testResetToPendingWithoutInstallablePendingBundleDoesNotResetState() {
        let resetPlugin = ResetTestableCapacitorUpdaterPlugin()
        let resetImplementation = ResetTrackingCapgoUpdater()
        resetImplementation.nextBundleValue = BundleInfo(
            id: "pending-id",
            version: "2.0.0",
            status: .PENDING,
            downloaded: Date(),
            checksum: "pending"
        )
        resetImplementation.canSetResult = false

        resetPlugin.implementation = resetImplementation

        XCTAssertFalse(resetPlugin._reset(toLastSuccessful: false, usePendingBundle: true))
        XCTAssertEqual(resetImplementation.canSetCalls, 1)
        XCTAssertEqual(resetImplementation.setCalls, 0)
        XCTAssertFalse(resetImplementation.resetCalled)
        XCTAssertEqual(resetImplementation.restoreResetStateCalls, 0)
    }

    func testResetToPendingRestoresStateWhenSwitchFails() {
        let resetPlugin = ResetTestableCapacitorUpdaterPlugin()
        let resetImplementation = ResetTrackingCapgoUpdater()
        resetImplementation.nextBundleValue = BundleInfo(
            id: "pending-id",
            version: "2.0.0",
            status: .PENDING,
            downloaded: Date(),
            checksum: "pending"
        )
        resetImplementation.setResult = false

        resetPlugin.implementation = resetImplementation

        XCTAssertFalse(resetPlugin._reset(toLastSuccessful: false, usePendingBundle: true))
        XCTAssertFalse(resetImplementation.resetCalled)
        XCTAssertTrue(resetImplementation.prepareResetStateForTransitionCalled)
        XCTAssertFalse(resetImplementation.finalizeResetTransitionCalled)
        XCTAssertEqual(resetImplementation.canSetCalls, 1)
        XCTAssertEqual(resetImplementation.setCalls, 1)
        XCTAssertEqual(resetImplementation.restoreResetStateCalls, 1)
        XCTAssertEqual(resetImplementation.restoredState?.currentBundlePath, resetImplementation.capturedState.currentBundlePath)
        XCTAssertEqual(resetImplementation.restoredState?.fallbackBundleId, resetImplementation.capturedState.fallbackBundleId)
        XCTAssertEqual(resetImplementation.restoredState?.nextBundleId, resetImplementation.capturedState.nextBundleId)
    }

    func testResetToPendingRestoresLiveStateWhenReloadFails() {
        let resetPlugin = ReloadFailureCapacitorUpdaterPlugin()
        let resetImplementation = ResetTrackingCapgoUpdater()
        resetImplementation.nextBundleValue = BundleInfo(
            id: "pending-id",
            version: "2.0.0",
            status: .PENDING,
            downloaded: Date(),
            checksum: "pending"
        )

        resetPlugin.implementation = resetImplementation

        XCTAssertFalse(resetPlugin._reset(toLastSuccessful: false, usePendingBundle: true))
        XCTAssertFalse(resetImplementation.resetCalled)
        XCTAssertTrue(resetImplementation.prepareResetStateForTransitionCalled)
        XCTAssertFalse(resetImplementation.finalizeResetTransitionCalled)
        XCTAssertEqual(resetImplementation.canSetCalls, 1)
        XCTAssertEqual(resetImplementation.setCalls, 1)
        XCTAssertEqual(resetImplementation.restoreResetStateCalls, 1)
        XCTAssertEqual(resetPlugin.restoreLiveBundleStateAfterFailedReloadCalls, 1)
        XCTAssertEqual(resetImplementation.restoredState?.currentBundlePath, resetImplementation.capturedState.currentBundlePath)
        XCTAssertEqual(resetImplementation.restoredState?.fallbackBundleId, resetImplementation.capturedState.fallbackBundleId)
        XCTAssertEqual(resetImplementation.restoredState?.nextBundleId, resetImplementation.capturedState.nextBundleId)
    }

    func testResetToPendingRestoresStateWhenBuiltinPendingReloadFails() {
        let resetPlugin = ReloadFailureCapacitorUpdaterPlugin()
        let resetImplementation = ResetTrackingCapgoUpdater()
        resetImplementation.nextBundleValue = BundleInfo(
            id: BundleInfo.ID_BUILTIN,
            version: "builtin",
            status: .SUCCESS,
            downloaded: BundleInfo.DOWNLOADED_BUILTIN,
            checksum: "builtin"
        )

        resetPlugin.implementation = resetImplementation

        XCTAssertFalse(resetPlugin._reset(toLastSuccessful: false, usePendingBundle: true))
        XCTAssertFalse(resetImplementation.resetCalled)
        XCTAssertTrue(resetImplementation.prepareResetStateForTransitionCalled)
        XCTAssertFalse(resetImplementation.finalizeResetTransitionCalled)
        XCTAssertEqual(resetImplementation.canSetCalls, 1)
        XCTAssertEqual(resetImplementation.setCalls, 0)
        XCTAssertEqual(resetImplementation.restoreResetStateCalls, 1)
        XCTAssertEqual(resetPlugin.restoreLiveBundleStateAfterFailedReloadCalls, 1)
        XCTAssertEqual(resetImplementation.restoredState?.currentBundlePath, resetImplementation.capturedState.currentBundlePath)
        XCTAssertEqual(resetImplementation.restoredState?.fallbackBundleId, resetImplementation.capturedState.fallbackBundleId)
        XCTAssertEqual(resetImplementation.restoredState?.nextBundleId, resetImplementation.capturedState.nextBundleId)
    }

    func testResetToLastSuccessfulWithoutInstallableFallbackFallsBackToBuiltin() {
        let resetPlugin = ResetTestableCapacitorUpdaterPlugin()
        let resetImplementation = ResetTrackingCapgoUpdater()
        resetImplementation.fallbackBundleValue = BundleInfo(
            id: "fallback-id",
            version: "1.5.0",
            status: .SUCCESS,
            downloaded: Date(),
            checksum: "fallback"
        )
        resetImplementation.canSetResult = false

        resetPlugin.implementation = resetImplementation

        XCTAssertTrue(resetPlugin._reset(toLastSuccessful: true, usePendingBundle: false))
        XCTAssertEqual(resetImplementation.canSetCalls, 1)
        XCTAssertEqual(resetImplementation.setCalls, 0)
        XCTAssertFalse(resetImplementation.resetCalled)
        XCTAssertTrue(resetImplementation.prepareResetStateForTransitionCalled)
        XCTAssertTrue(resetImplementation.finalizeResetTransitionCalled)
        XCTAssertEqual(resetImplementation.finalizeResetTransitionPreviousBundleName, "1.0.0")
        XCTAssertFalse(resetImplementation.finalizeResetTransitionIsInternal)
        XCTAssertEqual(resetImplementation.restoreResetStateCalls, 0)
    }

    func testResetToLastSuccessfulRestoresStateWhenSwitchFails() {
        let resetPlugin = ResetTestableCapacitorUpdaterPlugin()
        let resetImplementation = ResetTrackingCapgoUpdater()
        resetImplementation.fallbackBundleValue = BundleInfo(
            id: "fallback-id",
            version: "1.5.0",
            status: .SUCCESS,
            downloaded: Date(),
            checksum: "fallback"
        )
        resetImplementation.setResult = false

        resetPlugin.implementation = resetImplementation

        XCTAssertFalse(resetPlugin._reset(toLastSuccessful: true, usePendingBundle: false))
        XCTAssertFalse(resetImplementation.resetCalled)
        XCTAssertTrue(resetImplementation.prepareResetStateForTransitionCalled)
        XCTAssertFalse(resetImplementation.finalizeResetTransitionCalled)
        XCTAssertEqual(resetImplementation.canSetCalls, 1)
        XCTAssertEqual(resetImplementation.setCalls, 1)
        XCTAssertEqual(resetImplementation.restoreResetStateCalls, 1)
        XCTAssertEqual(resetImplementation.restoredState?.currentBundlePath, resetImplementation.capturedState.currentBundlePath)
        XCTAssertEqual(resetImplementation.restoredState?.fallbackBundleId, resetImplementation.capturedState.fallbackBundleId)
        XCTAssertEqual(resetImplementation.restoredState?.nextBundleId, resetImplementation.capturedState.nextBundleId)
    }

    func testReloadRestoresStateWhenPendingApplyReloadFails() throws {
        let reloadPlugin = ReloadFailureCapacitorUpdaterPlugin()
        let reloadImplementation = ResetTrackingCapgoUpdater()
        var rejected = false

        reloadImplementation.nextBundleValue = BundleInfo(
            id: "pending-id",
            version: "2.0.0",
            status: .PENDING,
            downloaded: Date(),
            checksum: "pending"
        )
        reloadPlugin.implementation = reloadImplementation

        let call = try XCTUnwrap(CAPPluginCall(
            callbackId: "reload-test",
            options: [:],
            success: { _, _ in
                XCTFail("reload should reject when the pending apply reload fails")
            },
            error: { _ in
                rejected = true
            }
        ))

        reloadPlugin.reload(call)

        XCTAssertTrue(rejected)
        XCTAssertEqual(reloadImplementation.setCalls, 0)
        XCTAssertEqual(reloadImplementation.stagePendingReloadCalls, 1)
        XCTAssertEqual(reloadImplementation.finalizePendingReloadCalls, 0)
        XCTAssertEqual(reloadImplementation.restoreResetStateCalls, 1)
        XCTAssertEqual(reloadPlugin.restoreLiveBundleStateAfterFailedReloadCalls, 1)
        XCTAssertEqual(reloadImplementation.restoredState?.currentBundlePath, reloadImplementation.capturedState.currentBundlePath)
        XCTAssertEqual(reloadImplementation.restoredState?.fallbackBundleId, reloadImplementation.capturedState.fallbackBundleId)
        XCTAssertEqual(reloadImplementation.restoredState?.nextBundleId, reloadImplementation.capturedState.nextBundleId)
    }

    func testReloadFinalizesPendingBundleSideEffectsAfterSuccess() throws {
        let reloadPlugin = ReloadBypassCapacitorUpdaterPlugin()
        let reloadImplementation = ResetTrackingCapgoUpdater()

        reloadImplementation.nextBundleValue = BundleInfo(
            id: "pending-id",
            version: "2.0.0",
            status: .PENDING,
            downloaded: Date(),
            checksum: "pending"
        )
        reloadPlugin.implementation = reloadImplementation

        let call = try XCTUnwrap(CAPPluginCall(
            callbackId: "reload-success-test",
            options: [:],
            success: { _, _ in },
            error: { _ in
                XCTFail("reload should resolve when the pending bundle reload succeeds")
            }
        ))

        reloadPlugin.reload(call)

        XCTAssertEqual(reloadImplementation.setCalls, 0)
        XCTAssertEqual(reloadImplementation.stagePendingReloadCalls, 1)
        XCTAssertEqual(reloadImplementation.finalizePendingReloadCalls, 1)
        XCTAssertEqual(reloadImplementation.finalizePendingReloadPreviousBundleName, "1.0.0")
        XCTAssertEqual(reloadImplementation.finalizedPendingReloadBundle?.getId(), "pending-id")
    }

    func testReloadRestoresStateWhenBuiltinPendingReloadFails() throws {
        let reloadPlugin = ReloadFailureCapacitorUpdaterPlugin()
        let reloadImplementation = ResetTrackingCapgoUpdater()
        var rejected = false

        reloadImplementation.nextBundleValue = BundleInfo(
            id: BundleInfo.ID_BUILTIN,
            version: "builtin",
            status: .SUCCESS,
            downloaded: BundleInfo.DOWNLOADED_BUILTIN,
            checksum: "builtin"
        )
        reloadPlugin.implementation = reloadImplementation

        let call = try XCTUnwrap(CAPPluginCall(
            callbackId: "reload-builtin-test",
            options: [:],
            success: { _, _ in
                XCTFail("reload should reject when the builtin pending reload fails")
            },
            error: { _ in
                rejected = true
            }
        ))

        reloadPlugin.reload(call)

        XCTAssertTrue(rejected)
        XCTAssertEqual(reloadImplementation.setCalls, 0)
        XCTAssertEqual(reloadImplementation.stagePendingReloadCalls, 0)
        XCTAssertEqual(reloadImplementation.finalizePendingReloadCalls, 0)
        XCTAssertTrue(reloadImplementation.prepareResetStateForTransitionCalled)
        XCTAssertFalse(reloadImplementation.finalizeResetTransitionCalled)
        XCTAssertEqual(reloadImplementation.restoreResetStateCalls, 1)
        XCTAssertEqual(reloadPlugin.restoreLiveBundleStateAfterFailedReloadCalls, 1)
        XCTAssertEqual(reloadImplementation.restoredState?.currentBundlePath, reloadImplementation.capturedState.currentBundlePath)
        XCTAssertEqual(reloadImplementation.restoredState?.fallbackBundleId, reloadImplementation.capturedState.fallbackBundleId)
        XCTAssertEqual(reloadImplementation.restoredState?.nextBundleId, reloadImplementation.capturedState.nextBundleId)
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

    func testDelayUntilNextDescription() {
        XCTAssertEqual(DelayUntilNext.background.description, "background")
        XCTAssertEqual(DelayUntilNext.kill.description, "kill")
        XCTAssertEqual(DelayUntilNext.nativeVersion.description, "nativeVersion")
        XCTAssertEqual(DelayUntilNext.date.description, "date")
    }

    func testDelayUntilNextEncodeDecode() throws {
        let original = DelayUntilNext.background

        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        // Decode
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DelayUntilNext.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - Logger Tests

    func testLoggerInitialization() {
        let logger = Logger(withTag: "TestTag")
        XCTAssertNotNil(logger)

        // Test different log levels
        logger.debug("Debug message")
        logger.info("Info message")
        logger.error("Error message")
        // No assertions here as logger just prints, but we ensure no crashes
    }

    // MARK: - UserDefaults Extension Tests

    func testSetAndGetObject() {
        let testObject = ["key": "value", "number": 42] as [String: Any]
        UserDefaults.standard.set(testObject, forKey: "test_object")

        let retrievedObject = UserDefaults.standard.object(forKey: "test_object") as? [String: Any]
        XCTAssertNotNil(retrievedObject)
        XCTAssertEqual(retrievedObject?["key"] as? String, "value")
        XCTAssertEqual(retrievedObject?["number"] as? Int, 42)

        // Clean up
        UserDefaults.standard.removeObject(forKey: "test_object")
    }

    func testSetAndGetDictionary() {
        let testDict = ["id": "1", "name": "Test"]
        UserDefaults.standard.set(testDict, forKey: "test_dict")

        let retrievedDict = UserDefaults.standard.dictionary(forKey: "test_dict")
        XCTAssertNotNil(retrievedDict)
        XCTAssertEqual(retrievedDict?["id"] as? String, "1")
        XCTAssertEqual(retrievedDict?["name"] as? String, "Test")

        // Clean up
        UserDefaults.standard.removeObject(forKey: "test_dict")
    }

    // MARK: - File System Tests

    func testFileOperations() {
        let testPath = NSTemporaryDirectory().appending("test_file.txt")
        let testContent = "Test content"

        // Test file creation
        let success = FileManager.default.createFile(
            atPath: testPath,
            contents: testContent.data(using: .utf8),
            attributes: nil
        )
        XCTAssertTrue(success)

        // Test file existence
        XCTAssertTrue(FileManager.default.fileExists(atPath: testPath))

        // Test file deletion
        do {
            try FileManager.default.removeItem(atPath: testPath)
            XCTAssertFalse(FileManager.default.fileExists(atPath: testPath))
        } catch {
            XCTFail("Failed to delete test file: \(error)")
        }
    }

    // MARK: - Bundle Path Tests

    func testBundlePathGeneration() {
        let bundleId = "test-bundle-123"

        // Generate a mock bundle path
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        let bundlePath = documentsPath.appending("/\(bundleId)")

        XCTAssertTrue(bundlePath.contains(bundleId))
        XCTAssertTrue(bundlePath.contains("Documents"))
    }

    // MARK: - Date Extension Tests

    func testDateISO8601Formatting() {
        let date = Date(timeIntervalSince1970: 0)
        let formatted = date.iso8601withFractionalSeconds

        XCTAssertNotNil(formatted)
        XCTAssertTrue(formatted.contains("1970"))
    }

    // MARK: - String Extension Tests

    func testStringTrim() {
        let testString = "  test string  "
        let trimmed = testString.trim()

        XCTAssertEqual(trimmed, "test string")
    }

    func testStringTrimWithNewlines() {
        let testString = "\n\ntest\n\n"
        let trimmed = testString.trim()

        XCTAssertEqual(trimmed, "test")
    }

    // MARK: - CapgoUpdater Tests

    func testCapgoUpdaterInitialization() {
        let updater = CapgoUpdater()
        XCTAssertNotNil(updater)
    }

    // MARK: - Performance Tests

    func testPerformanceStringTrim() {
        let testString = "  test string with spaces  "

        self.measure {
            for _ in 0..<10000 {
                _ = testString.trim()
            }
        }
    }

    func testPerformanceDateFormatting() {
        let date = Date()

        self.measure {
            for _ in 0..<1000 {
                _ = date.iso8601withFractionalSeconds
            }
        }
    }

    func testPerformanceBundleInfoEncoding() {
        let bundleInfo = BundleInfo(
            id: "test-id",
            version: "1.0.0",
            status: .SUCCESS,
            downloaded: Date(),
            checksum: "abc123"
        )

        self.measure {
            for _ in 0..<1000 {
                if let data = try? JSONEncoder().encode(bundleInfo) {
                    _ = try? JSONDecoder().decode(BundleInfo.self, from: data)
                }
            }
        }
    }

    func testPerformanceDelayConditionOperations() {
        let condition = DelayCondition(kind: .background, value: "test")

        self.measure {
            for _ in 0..<1000 {
                _ = condition.toJSON()
                _ = condition.toString()
                _ = condition.getKind()
            }
        }
    }
}
