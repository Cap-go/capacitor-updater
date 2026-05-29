import XCTest
@testable import CapacitorUpdaterPlugin
import Capacitor
import Version

extension CapacitorUpdaterTests {
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

    func testPeriodCheckDelayZeroDisablesPeriodicChecks() {
        XCTAssertEqual(CapacitorUpdaterPlugin.normalizedPeriodCheckDelaySeconds(0), 0)
    }

    func testPeriodCheckDelayNegativeDisablesPeriodicChecks() {
        XCTAssertEqual(CapacitorUpdaterPlugin.normalizedPeriodCheckDelaySeconds(-1), 0)
    }

    func testPeriodCheckDelayBelowMinimumClampsToTenMinutes() {
        XCTAssertEqual(CapacitorUpdaterPlugin.normalizedPeriodCheckDelaySeconds(1), 600)
        XCTAssertEqual(CapacitorUpdaterPlugin.normalizedPeriodCheckDelaySeconds(599), 600)
    }

    func testPeriodCheckDelayAtMinimumIsAllowed() {
        XCTAssertEqual(CapacitorUpdaterPlugin.normalizedPeriodCheckDelaySeconds(600), 600)
    }

    func testPeriodCheckDelayAboveMinimumIsPreserved() {
        XCTAssertEqual(CapacitorUpdaterPlugin.normalizedPeriodCheckDelaySeconds(3600), 3600)
    }

    func testLegacyReloadSelectorIsStillExposed() {
        let plugin = CapacitorUpdaterPlugin()

        XCTAssertTrue(plugin.responds(to: NSSelectorFromString("_reload")))
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

        XCTAssertFalse(resetPlugin.resetToTarget(toLastSuccessful: false, usePendingBundle: true))
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

        XCTAssertFalse(resetPlugin.resetToTarget(toLastSuccessful: false, usePendingBundle: true))
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

        XCTAssertFalse(resetPlugin.resetToTarget(toLastSuccessful: false, usePendingBundle: true))
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
            id: BundleInfo.idBuiltin,
            version: "builtin",
            status: .SUCCESS,
            downloaded: BundleInfo.downloadedBuiltin,
            checksum: "builtin"
        )

        resetPlugin.implementation = resetImplementation

        XCTAssertFalse(resetPlugin.resetToTarget(toLastSuccessful: false, usePendingBundle: true))
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

        XCTAssertTrue(resetPlugin.resetToTarget(toLastSuccessful: true, usePendingBundle: false))
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

        XCTAssertFalse(resetPlugin.resetToTarget(toLastSuccessful: true, usePendingBundle: false))
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

    func testResetToLastSuccessfulRestoresStateWhenFallbackReloadFails() {
        let resetPlugin = SequenceReloadCapacitorUpdaterPlugin()
        let resetImplementation = ResetTrackingCapgoUpdater()
        resetPlugin.reloadResults = [false]
        resetImplementation.fallbackBundleValue = BundleInfo(
            id: "fallback-id",
            version: "1.5.0",
            status: .SUCCESS,
            downloaded: Date(),
            checksum: "fallback"
        )

        resetPlugin.implementation = resetImplementation

        XCTAssertFalse(resetPlugin.resetToTarget(toLastSuccessful: true, usePendingBundle: false))
        XCTAssertTrue(resetImplementation.prepareResetStateForTransitionCalled)
        XCTAssertEqual(resetImplementation.prepareResetStateForTransitionCalls, 1)
        XCTAssertFalse(resetImplementation.finalizeResetTransitionCalled)
        XCTAssertEqual(resetImplementation.canSetCalls, 1)
        XCTAssertEqual(resetImplementation.setCalls, 1)
        XCTAssertEqual(resetImplementation.restoreResetStateCalls, 1)
        XCTAssertEqual(resetPlugin.restoreLiveBundleStateAfterFailedReloadCalls, 1)
        XCTAssertEqual(resetImplementation.restoredState?.currentBundlePath, resetImplementation.capturedState.currentBundlePath)
        XCTAssertEqual(resetImplementation.restoredState?.fallbackBundleId, resetImplementation.capturedState.fallbackBundleId)
        XCTAssertEqual(resetImplementation.restoredState?.nextBundleId, resetImplementation.capturedState.nextBundleId)
    }

    func testInternalResetToLastSuccessfulFallsBackToBuiltinWhenFallbackReloadFails() {
        let resetPlugin = SequenceReloadCapacitorUpdaterPlugin()
        let resetImplementation = ResetTrackingCapgoUpdater()
        resetPlugin.reloadResults = [false, true]
        resetImplementation.currentBundleValue = BundleInfo(
            id: "current-id",
            version: "2.0.0",
            status: .ERROR,
            downloaded: Date(),
            checksum: "abc123"
        )
        resetImplementation.fallbackBundleValue = BundleInfo(
            id: "fallback-id",
            version: "1.5.0",
            status: .SUCCESS,
            downloaded: Date(),
            checksum: "fallback"
        )

        resetPlugin.implementation = resetImplementation

        XCTAssertTrue(resetPlugin.performReset(toLastSuccessful: true, usePendingBundle: false, isInternal: true))
        XCTAssertTrue(resetImplementation.prepareResetStateForTransitionCalled)
        XCTAssertEqual(resetImplementation.prepareResetStateForTransitionCalls, 2)
        XCTAssertTrue(resetImplementation.finalizeResetTransitionCalled)
        XCTAssertEqual(resetImplementation.finalizeResetTransitionCalls, 1)
        XCTAssertEqual(resetImplementation.finalizeResetTransitionPreviousBundleName, "2.0.0")
        XCTAssertTrue(resetImplementation.finalizeResetTransitionIsInternal)
        XCTAssertEqual(resetImplementation.canSetCalls, 1)
        XCTAssertEqual(resetImplementation.setCalls, 1)
        XCTAssertEqual(resetImplementation.restoreResetStateCalls, 0)
        XCTAssertEqual(resetPlugin.restoreLiveBundleStateAfterFailedReloadCalls, 0)
    }

    func testFinalizePendingReloadPreservesSuccessfulBundleStatus() {
        let updater = PendingReloadFinalizeCapgoUpdater()
        let successfulBundle = BundleInfo(
            id: "pending-id",
            version: "2.0.0",
            status: .SUCCESS,
            downloaded: Date(),
            checksum: "pending"
        )
        let pendingBundle = BundleInfo(
            id: "pending-id",
            version: "2.0.0",
            status: .PENDING,
            downloaded: Date(),
            checksum: "pending"
        )
        updater.bundleInfos["pending-id"] = successfulBundle

        updater.finalizePendingReload(bundle: pendingBundle, previousBundleName: "1.0.0")

        XCTAssertEqual(updater.bundleInfos["pending-id"]?.getStatus(), BundleStatus.SUCCESS.storedValue)
        XCTAssertEqual(updater.lastStatsAction, "set")
        XCTAssertEqual(updater.lastStatsVersionName, "2.0.0")
        XCTAssertEqual(updater.lastStatsOldVersionName, "1.0.0")
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
        let resolved = expectation(description: "reload resolves on pending bundle success")

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
            success: { _, _ in
                resolved.fulfill()
            },
            error: { _ in
                XCTFail("reload should resolve when the pending bundle reload succeeds")
            }
        ))

        reloadPlugin.reload(call)
        wait(for: [resolved], timeout: 1.0)

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
            id: BundleInfo.idBuiltin,
            version: "builtin",
            status: .SUCCESS,
            downloaded: BundleInfo.downloadedBuiltin,
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

}
