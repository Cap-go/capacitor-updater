import XCTest
@testable import CapacitorUpdaterPlugin
import Capacitor
import Version

class TestableCapacitorUpdaterPlugin: CapacitorUpdaterPlugin {
    private(set) var notifiedEventNames: [String] = []
    private(set) var notifiedEventPayloads: [String: [String: Any]] = [:]
    private(set) var notifiedEventRetainValues: [String: Bool] = [:]

    override func notifyListeners(_ eventName: String, data: [String: Any]?, retainUntilConsumed retain: Bool) {
        notifiedEventNames.append(eventName)
        notifiedEventRetainValues[eventName] = retain
        if let data {
            notifiedEventPayloads[eventName] = data
        }
    }

    override func endBackGroundTask() {
        // Intentionally blank: tests avoid touching UIApplication background-task APIs.
    }

    override func runBackgroundDownloadWork(_ work: @escaping () -> Void) {
        work()
    }

    override func runGetLatestWork(_ work: @escaping () -> Void) {
        work()
    }

    override func sendReadyToJs(current: BundleInfo, msg: String) {
        // Intentionally blank: tests assert native state transitions without JS bridge side effects.
    }
}

final class FreshDownloadCapgoUpdater: CapgoUpdater {
    var currentBundleValue: BundleInfo!
    var latestResponse = AppVersion()
    var existingBundleValue: BundleInfo?
    var downloadedBundleValue: BundleInfo?
    var builtinBundleValue = BundleInfo(
        id: BundleInfo.idBuiltin,
        version: "builtin",
        status: .SUCCESS,
        downloaded: BundleInfo.downloadedBuiltin,
        checksum: "builtin"
    )
    var onDownloadStart: (() -> Void)?
    var setNextBundleCalls = 0
    var lastSetNextBundleId: String?
    var sentStatsActions: [String] = []

    override func getLatest(url: URL, channel: String?, appIdOverride: String? = nil) -> AppVersion {
        latestResponse
    }

    override func getCurrentBundle() -> BundleInfo {
        currentBundleValue
    }

    override func getBundleInfoByVersionName(version: String) -> BundleInfo? {
        guard existingBundleValue?.getVersionName() == version else {
            return nil
        }
        return existingBundleValue
    }

    override func getBundleInfo(id: String?) -> BundleInfo {
        if id == BundleInfo.idBuiltin {
            return builtinBundleValue
        }
        return currentBundleValue
    }

    override func download(url: URL, version: String, sessionKey: String, link: String? = nil, comment: String? = nil) throws -> BundleInfo {
        onDownloadStart?()
        if let downloadedBundleValue {
            return downloadedBundleValue
        }
        throw NSError(domain: "CapacitorUpdaterPluginTests", code: 1)
    }

    override func setNextBundle(next: String?) -> Bool {
        setNextBundleCalls += 1
        lastSetNextBundleId = next
        return true
    }

    override func sendStats(action: String, versionName: String? = nil, oldVersionName: String? = "") {
        sentStatsActions.append(action)
    }
}

final class HealthStatsCapgoUpdater: CapgoUpdater {
    var currentBundleValue = BundleInfo(
        id: "current-id",
        version: "1.0.0",
        status: .SUCCESS,
        downloaded: Date(),
        checksum: "abc123"
    )
    var sentStatsActions: [String] = []
    var lastStatsVersionName: String?
    var lastStatsOldVersionName: String?
    var lastStatsMetadata: [String: String]?

    override func getCurrentBundle() -> BundleInfo {
        currentBundleValue
    }

    override func sendStats(action: String, versionName: String? = nil, oldVersionName: String? = "") {
        sentStatsActions.append(action)
        lastStatsVersionName = versionName
        lastStatsOldVersionName = oldVersionName
        lastStatsMetadata = nil
    }

    override func sendStats(action: String, versionName: String?, oldVersionName: String?, metadata: [String: String]) {
        sentStatsActions.append(action)
        lastStatsVersionName = versionName
        lastStatsOldVersionName = oldVersionName
        lastStatsMetadata = metadata
    }
}

final class ChannelRequestCapgoUpdater: CapgoUpdater {
    var requestResult: CapgoUpdater.RequestResult!
    var lastRequest: URLRequest?

    override func performRequest(_ request: URLRequest, label: String) -> CapgoUpdater.RequestResult {
        lastRequest = request
        return requestResult
    }
}

final class ResetTrackingCapgoUpdater: CapgoUpdater {
    var currentBundleValue = BundleInfo(
        id: "current-id",
        version: "1.0.0",
        status: .SUCCESS,
        downloaded: Date(),
        checksum: "abc123"
    )
    var fallbackBundleValue = BundleInfo(
        id: BundleInfo.idBuiltin,
        version: "builtin",
        status: .SUCCESS,
        downloaded: BundleInfo.downloadedBuiltin,
        checksum: "builtin"
    )
    var nextBundleValue: BundleInfo?
    var resetCalled = false
    var resetIsInternal = false
    var prepareResetStateForTransitionCalled = false
    var prepareResetStateForTransitionCalls = 0
    var finalizeResetTransitionCalled = false
    var finalizeResetTransitionCalls = 0
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
        resetIsInternal = isInternal
    }

    override func prepareResetStateForTransition() {
        prepareResetStateForTransitionCalled = true
        prepareResetStateForTransitionCalls += 1
    }

    override func finalizeResetTransition(previousBundleName: String, isInternal: Bool) {
        finalizeResetTransitionCalled = true
        finalizeResetTransitionCalls += 1
        finalizeResetTransitionPreviousBundleName = previousBundleName
        finalizeResetTransitionIsInternal = isInternal
    }
}

final class ResetTestableCapacitorUpdaterPlugin: TestableCapacitorUpdaterPlugin {
    override func canPerformResetTransition() -> Bool {
        true
    }

    override func reloadCurrentBundle() -> Bool {
        true
    }
}

final class ReloadBypassCapacitorUpdaterPlugin: TestableCapacitorUpdaterPlugin {
    override func reloadCurrentBundle() -> Bool {
        true
    }
}

final class ReloadFailureCapacitorUpdaterPlugin: TestableCapacitorUpdaterPlugin {
    var restoreLiveBundleStateAfterFailedReloadCalls = 0

    override func canPerformResetTransition() -> Bool {
        true
    }

    override func reloadCurrentBundle() -> Bool {
        false
    }

    override func restoreLiveBundleStateAfterFailedReload() {
        restoreLiveBundleStateAfterFailedReloadCalls += 1
    }
}

final class SequenceReloadCapacitorUpdaterPlugin: TestableCapacitorUpdaterPlugin {
    var reloadResults = [false]
    var reloadCallCount = 0
    var restoreLiveBundleStateAfterFailedReloadCalls = 0

    override func canPerformResetTransition() -> Bool {
        true
    }

    override func reloadCurrentBundle() -> Bool {
        let resultIndex = min(reloadCallCount, reloadResults.count - 1)
        reloadCallCount += 1
        return reloadResults[resultIndex]
    }

    override func restoreLiveBundleStateAfterFailedReload() {
        restoreLiveBundleStateAfterFailedReloadCalls += 1
    }
}

final class PendingReloadFinalizeCapgoUpdater: CapgoUpdater {
    var bundleInfos: [String: BundleInfo] = [:]
    var lastStatsAction: String?
    var lastStatsVersionName: String?
    var lastStatsOldVersionName: String?

    override func getBundleInfo(id: String?) -> BundleInfo {
        bundleInfos[id!]!
    }

    override func saveBundleInfo(id: String, bundle: BundleInfo?) {
        bundleInfos[id] = bundle
    }

    override func sendStats(action: String, versionName: String? = nil, oldVersionName: String? = "") {
        lastStatsAction = action
        lastStatsVersionName = versionName
        lastStatsOldVersionName = oldVersionName
    }
}

class CapacitorUpdaterTests: XCTestCase {

    var plugin: CapacitorUpdaterPlugin!
    var implementation: CapgoUpdater!
    let delayPreferencesKey = DelayUpdateUtils.delayConditionPreferences
    let backgroundTimestampKey = DelayUpdateUtils.backgroundTimestampKey
    let onlyDownloadChecksum = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

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

    func makeOnlyDownloadBundle(
        id: String = "downloaded-id",
        version: String = "2.0.0",
        status: BundleStatus = .PENDING,
        checksum: String? = nil
    ) -> BundleInfo {
        BundleInfo(
            id: id,
            version: version,
            status: status,
            downloaded: Date(),
            checksum: checksum ?? onlyDownloadChecksum
        )
    }

    func makeOnlyDownloadLatest() -> AppVersion {
        let latest = AppVersion()
        latest.version = "2.0.0"
        latest.url = "https://example.com/update.zip"
        latest.checksum = onlyDownloadChecksum
        return latest
    }

    func makeOnlyDownloadPlugin(
        current: BundleInfo? = nil,
        existing: BundleInfo? = nil,
        downloaded: BundleInfo? = nil
    ) -> (TestableCapacitorUpdaterPlugin, FreshDownloadCapgoUpdater) {
        let freshDownloadImplementation = FreshDownloadCapgoUpdater()
        freshDownloadImplementation.currentBundleValue = current ?? makeOnlyDownloadBundle(
            id: "test-id",
            version: "1.0.0",
            status: .SUCCESS,
            checksum: "abc123"
        )
        freshDownloadImplementation.latestResponse = makeOnlyDownloadLatest()
        freshDownloadImplementation.existingBundleValue = existing
        freshDownloadImplementation.downloadedBundleValue = downloaded

        let testPlugin = TestableCapacitorUpdaterPlugin()
        testPlugin.implementation = freshDownloadImplementation
        testPlugin.setAutoUpdateModeForTesting("onlyDownload")
        testPlugin.setUpdateUrlForTesting("https://example.com/channel")
        CryptoCipher.setLogger(Logger(withTag: "TestLogger"))

        return (testPlugin, freshDownloadImplementation)
    }

    func assertOnlyDownloadLeavesUpdateManual(
        plugin testPlugin: TestableCapacitorUpdaterPlugin,
        implementation freshDownloadImplementation: FreshDownloadCapgoUpdater
    ) {
        XCTAssertTrue(testPlugin.notifiedEventNames.contains("updateAvailable"))
        XCTAssertEqual(testPlugin.notifiedEventRetainValues["updateAvailable"], true)
        XCTAssertFalse(testPlugin.notifiedEventNames.contains("noNeedUpdate"))
        XCTAssertEqual(freshDownloadImplementation.setNextBundleCalls, 0)
        XCTAssertNil(freshDownloadImplementation.lastSetNextBundleId)
    }

    func makeDelayUpdateUtils() throws -> DelayUpdateUtils {
        let logger = Logger(withTag: "TestLogger")
        let version = try Version("1.0.0")
        return DelayUpdateUtils(currentVersionNative: version, logger: logger)
    }

    func clearDelayStorage() {
        UserDefaults.standard.removeObject(forKey: delayPreferencesKey)
        UserDefaults.standard.removeObject(forKey: backgroundTimestampKey)
    }
}
