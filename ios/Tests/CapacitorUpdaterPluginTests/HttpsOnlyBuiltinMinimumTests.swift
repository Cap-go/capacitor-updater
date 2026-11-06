import XCTest
import Capacitor
@testable import CapacitorUpdaterPlugin

/// `httpsOnly` download gates and `builtinMinimum` download and activation gates.
final class HttpsOnlyBuiltinMinimumTests: XCTestCase {
    private final class StatsTrackingCapgoUpdater: CapgoUpdater {
        var sentStatsActions: [String] = []

        override func sendStats(action: String, versionName: String? = nil, oldVersionName: String? = "") {
            sentStatsActions.append(action)
        }
    }

    private func makeUpdater() -> StatsTrackingCapgoUpdater {
        let updater = StatsTrackingCapgoUpdater()
        updater.setLogger(Logger(withTag: "HttpsOnlyBuiltinMinimumTests", options: Logger.Options(level: .silent)))
        return updater
    }

    private final class ReloadTrackingPlugin: CapacitorUpdaterPlugin {
        var reloadCalls = 0

        /// Simulates a successful WebView reload and records whether activation reached that step.
        override func _reload() -> Bool {
            reloadCalls += 1
            return true
        }

        override func restoreLiveBundleStateAfterFailedReload() {}
    }

    /// Persists a real downloaded bundle and restores the active, fallback and pending state after the test.
    private func withStoredBundle(
        version: String,
        _ body: (StatsTrackingCapgoUpdater, BundleInfo) throws -> Void
    ) throws {
        let updater = makeUpdater()
        let previousState = updater.captureResetState()
        let bundle = BundleInfo(id: UUID().uuidString, version: version, status: .SUCCESS, downloaded: Date(), checksum: "abc")
        let directory = try updater.getBundleDirectory(id: bundle.getId())
        defer {
            updater.restoreResetState(previousState)
            updater.saveBundleInfo(id: bundle.getId(), bundle: nil)
            try? FileManager.default.removeItem(at: directory)
            updater.shutdown()
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "<html>retained bundle</html>".write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        XCTAssertTrue(updater.saveBundleInfo(id: bundle.getId(), bundle: bundle))
        updater.prepareResetStateForTransition()
        updater.versionBuild = "2.0.0"
        try body(updater, bundle)
    }

    func testDefaultsAreHttpsOnlyOnAndBuiltinMinimumOn() throws {
        let updater = makeUpdater()
        XCTAssertTrue(updater.httpsOnly)
        XCTAssertTrue(updater.builtinMinimum)
        XCTAssertTrue(RedirectPolicyDelegate().httpsOnly)
        updater.versionBuild = "2.0.0"
        XCTAssertNoThrow(try updater.requireVersionNotBelowBuiltin("2.0.0"))
        XCTAssertThrowsError(try updater.requireVersionNotBelowBuiltin("1.0.0"))
        XCTAssertNotNil(updater.checkAllowedScheme(try XCTUnwrap(URL(string: "http://example.com/a.zip"))))
        XCTAssertEqual(updater.sentStatsActions, ["version_below_native"])
    }

    // MARK: - builtinMinimum

    func testBuiltinMinimumRejectsVersionBelowNative() throws {
        let updater = makeUpdater()
        updater.builtinMinimum = true
        updater.versionBuild = "2.0.0"
        XCTAssertThrowsError(try updater.requireVersionNotBelowBuiltin("1.9.9")) { error in
            XCTAssertEqual((error as NSError).code, 8)
            XCTAssertEqual(
                (error as NSError).localizedDescription,
                "Bundle version 1.9.9 is below native version 2.0.0 (builtinMinimum)"
            )
        }
        XCTAssertEqual(updater.sentStatsActions, ["version_below_native"])
        XCTAssertNoThrow(try updater.requireVersionNotBelowBuiltin("2.0.0"))
        XCTAssertNoThrow(try updater.requireVersionNotBelowBuiltin("2.0.1"))
        XCTAssertNoThrow(try updater.requireVersionNotBelowBuiltin("2.0.0-beta.1"))
        XCTAssertThrowsError(try updater.requireVersionNotBelowBuiltin("1.9.9-rc.1"))
        // Dotted build metadata must not disable the floor.
        XCTAssertThrowsError(try updater.requireVersionNotBelowBuiltin("1.9.9+build.42"))
        XCTAssertNoThrow(try updater.requireVersionNotBelowBuiltin("2.0.0+build.42"))
        updater.versionBuild = "2.0.0+ci.7"
        XCTAssertThrowsError(try updater.requireVersionNotBelowBuiltin("1.9.9"))
        // Unparseable versions never block.
        XCTAssertNoThrow(try updater.requireVersionNotBelowBuiltin("builtin"))
        updater.versionBuild = "not-a-version"
        XCTAssertNoThrow(try updater.requireVersionNotBelowBuiltin("0.0.1"))
    }

    func testBuiltinMinimumGatesDownloadBeforeNetwork() throws {
        let updater = makeUpdater()
        updater.builtinMinimum = true
        updater.versionBuild = "3.0.0"
        let url = try XCTUnwrap(URL(string: "https://example.com/update.zip"))
        XCTAssertThrowsError(
            try updater.downloadVerified(url: url, version: "2.0.0", sessionKey: "", expectedChecksum: "abc")
        ) { error in
            XCTAssertEqual((error as NSError).code, 8)
        }
        let manifest = [
            ManifestEntry(file_name: "index.html", file_hash: "00", download_url: "https://example.com/f")
        ]
        XCTAssertThrowsError(
            try updater.downloadManifest(manifest: manifest, version: "2.0.0", sessionKey: "")
        ) { error in
            XCTAssertEqual((error as NSError).code, 8)
        }
    }

    /// A native upgrade must not let manual set reactivate an older stored bundle or mark it corrupt.
    func testManualSetRejectsRetainedBundleWithoutChangingState() throws {
        try withStoredBundle(version: "1.9.9") { updater, bundle in
            let previousState = updater.captureResetState()

            XCTAssertFalse(updater.set(id: bundle.getId()))

            XCTAssertEqual(updater.captureResetState().currentBundlePath, previousState.currentBundlePath)
            XCTAssertEqual(updater.getBundleInfo(id: bundle.getId()).getStatus(), BundleStatus.SUCCESS.storedValue)
            XCTAssertEqual(updater.sentStatsActions, ["version_below_native"])
        }
    }

    /// Explicit reload must reject an incompatible pending bundle before reloading or clearing its ID.
    func testReloadRejectsRetainedBundleAndKeepsItPending() throws {
        try withStoredBundle(version: "1.9.9") { updater, bundle in
            XCTAssertTrue(updater.setNextBundle(next: bundle.getId()))
            let previousState = updater.captureResetState()
            let plugin = ReloadTrackingPlugin()
            plugin.implementation = updater
            var rejected = false
            let call = try XCTUnwrap(CAPPluginCall(
                callbackId: "reload-version-floor",
                methodName: "reload",
                options: [:],
                success: { _, _ in XCTFail("Reload must reject the old bundle") },
                error: { _ in rejected = true }
            ))

            plugin.reload(call)

            XCTAssertTrue(rejected)
            XCTAssertEqual(plugin.reloadCalls, 0)
            XCTAssertEqual(updater.captureResetState().currentBundlePath, previousState.currentBundlePath)
            XCTAssertEqual(updater.captureResetState().fallbackBundleId, previousState.fallbackBundleId)
            XCTAssertEqual(updater.getNextBundle()?.getId(), bundle.getId())
            XCTAssertEqual(updater.getBundleInfo(id: bundle.getId()).getStatus(), BundleStatus.PENDING.storedValue)
            XCTAssertEqual(updater.sentStatsActions, ["set_next", "version_below_native"])
        }
    }

    /// Both activation entry points accept stored bundles at or above the native version.
    func testStoredBundleActivationAcceptsEqualOrNewerVersions() throws {
        for version in ["2.0.0", "2.0.1"] {
            try withStoredBundle(version: version) { updater, bundle in
                XCTAssertTrue(updater.set(id: bundle.getId()))
                XCTAssertEqual(updater.getCurrentBundleId(), bundle.getId())
                updater.prepareResetStateForTransition()
                XCTAssertTrue(updater.stagePendingReload(bundle: bundle))
                XCTAssertEqual(updater.getCurrentBundleId(), bundle.getId())
            }
        }
    }

    /// Independent web versioning still works when the app explicitly disables the version floor.
    func testStoredBundleActivationAllowsExplicitOptOut() throws {
        try withStoredBundle(version: "1.9.9") { updater, bundle in
            updater.builtinMinimum = false
            XCTAssertTrue(updater.set(id: bundle.getId()))
            XCTAssertEqual(updater.getCurrentBundleId(), bundle.getId())
            updater.prepareResetStateForTransition()
            XCTAssertTrue(updater.stagePendingReload(bundle: bundle))
            XCTAssertEqual(updater.getCurrentBundleId(), bundle.getId())
        }
    }

    /// A rejected pending update must not prevent the app from resetting to its builtin bundle.
    func testBuiltinResetClearsRejectedPendingBundle() throws {
        try withStoredBundle(version: "1.9.9") { updater, bundle in
            XCTAssertTrue(updater.setNextBundle(next: bundle.getId()))
            XCTAssertFalse(updater.stagePendingReload(bundle: bundle))

            XCTAssertTrue(updater.set(id: BundleInfo.ID_BUILTIN))

            XCTAssertTrue(updater.getCurrentBundle().isBuiltin())
            XCTAssertTrue(updater.getNextBundle()?.isUnknown() ?? true)
        }
    }

    /// Restoring a WebView's previous bundle after a failed transition is not a new activation.
    func testFailedReloadCanRestoreAnExistingOlderBundle() throws {
        try withStoredBundle(version: "1.9.9") { updater, bundle in
            updater.restoreCurrentBundle(bundle)

            XCTAssertEqual(updater.getCurrentBundleId(), bundle.getId())
            XCTAssertTrue(updater.sentStatsActions.isEmpty)
        }
    }

    // MARK: - httpsOnly

    func testHttpsOnlyRejectsPlainHttpBeforeNetwork() throws {
        let updater = makeUpdater()
        updater.httpsOnly = true
        let httpUrl = try XCTUnwrap(URL(string: "http://example.com/update.zip"))
        XCTAssertThrowsError(
            try updater.downloadVerified(url: httpUrl, version: "1.0.0", sessionKey: "", expectedChecksum: "abc")
        ) { error in
            XCTAssertEqual(
                (error as NSError).localizedDescription,
                "httpsOnly is enabled and http://example.com/update.zip is not https"
            )
        }
        let manifest = [
            ManifestEntry(file_name: "index.html", file_hash: "00", download_url: "http://example.com/f")
        ]
        XCTAssertThrowsError(
            try updater.downloadManifest(manifest: manifest, version: "1.0.0", sessionKey: "")
        ) { error in
            XCTAssertEqual((error as NSError).code, 7)
        }

        let done = expectation(description: "raw task rejected")
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:1/updates")))
        request.timeoutInterval = 1
        updater.startRawDataTask(request) { data, _, error in
            XCTAssertNil(data)
            XCTAssertEqual((error as NSError?)?.code, 7)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        updater.httpsOnly = false
        XCTAssertNil(updater.checkAllowedScheme(httpUrl))
    }

    func testHttpsOnlyBlocksRedirectToHttpEvenWhenDowngradeAllowed() throws {
        let delegate = RedirectPolicyDelegate()
        delegate.allowHttpsToHttpRedirect = true
        delegate.httpsOnly = true
        var blocked = false
        delegate.onBlockedRedirect = { _, _ in blocked = true }
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: try XCTUnwrap(URL(string: "https://example.com/a")))
        let sourceUrl = try XCTUnwrap(URL(string: "https://example.com/a"))
        let response = try XCTUnwrap(
            HTTPURLResponse(url: sourceUrl, statusCode: 302, httpVersion: nil, headerFields: nil)
        )
        let httpRequest = URLRequest(url: try XCTUnwrap(URL(string: "http://example.com/b")))
        let placeholder = try XCTUnwrap(URL(string: "https://placeholder"))
        var forwarded: URLRequest? = URLRequest(url: placeholder)
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: httpRequest) {
            forwarded = $0
        }
        XCTAssertNil(forwarded)
        XCTAssertTrue(blocked)

        delegate.httpsOnly = false
        blocked = false
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: httpRequest) {
            forwarded = $0
        }
        XCTAssertNotNil(forwarded)
        XCTAssertFalse(blocked)
    }
}
