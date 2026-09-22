import XCTest
@testable import CapacitorUpdaterPlugin

final class SessionKeyRequiredTests: XCTestCase {
    private enum Fixture {
        static let contract: [String: Any] = {
            guard let url = try? locateContractFile(),
                  let data = try? Data(contentsOf: url),
                  let value = try? JSONSerialization.jsonObject(with: data),
                  let dict = value as? [String: Any] else {
                XCTFail("Unable to load RSA contract fixture")
                return [:]
            }
            return dict
        }()

        static var publicKeyPem: String {
            contract["publicKeyPem"] as? String ?? ""
        }

        private static func locateContractFile() throws -> URL {
            let fileManager = FileManager.default
            let roots = [
                URL(fileURLWithPath: fileManager.currentDirectoryPath),
                URL(fileURLWithPath: #filePath)
            ]

            for root in roots {
                var current = root
                while current.path != "/" {
                    let candidate = current
                        .appendingPathComponent("native-contract-tests")
                        .appendingPathComponent("crypto-rsa.json")
                    if fileManager.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                    current.deleteLastPathComponent()
                }
            }
            throw NSError(domain: "SessionKeyRequiredTests", code: 1)
        }
    }

    private class StatsTrackingCapgoUpdater: CapgoUpdater {
        var sentStatsActions: [String] = []

        override func sendStats(action: String, versionName: String? = nil, oldVersionName: String? = "") {
            sentStatsActions.append(action)
        }
    }

    private final class AutoUpdateSessionKeyCapgoUpdater: StatsTrackingCapgoUpdater {
        override func getLatest(url: URL, channel: String?, appIdOverride: String? = nil) -> AppVersion {
            let latest = AppVersion()
            latest.version = "2.0.0"
            latest.url = "https://example.com/update.zip"
            return latest
        }

        override func getCurrentBundle() -> BundleInfo {
            BundleInfo(id: "current-id", version: "1.0.0", status: .SUCCESS, downloaded: Date(), checksum: "abc")
        }
    }

    private final class PendingBundleAutoUpdateCapgoUpdater: StatsTrackingCapgoUpdater {
        override func getLatest(url: URL, channel: String?, appIdOverride: String? = nil) -> AppVersion {
            let latest = AppVersion()
            latest.version = "2.0.0"
            latest.url = "https://example.com/update.zip"
            latest.checksum = "abc123"
            return latest
        }

        override func getCurrentBundle() -> BundleInfo {
            BundleInfo(id: "current-id", version: "1.0.0", status: .SUCCESS, downloaded: Date(), checksum: "abc")
        }

        override func getBundleInfoByVersionName(version: String) -> BundleInfo? {
            if version == "2.0.0" {
                return BundleInfo(
                    id: "pending-id",
                    version: "2.0.0",
                    status: .PENDING,
                    downloaded: Date(),
                    checksum: "abc123"
                )
            }
            return nil
        }
    }

    private final class TestableCapacitorUpdaterPlugin: CapacitorUpdaterPlugin {
        override func runBackgroundDownloadWork(_ work: @escaping () -> Void) {
            work()
        }
    }

    private var implementation: StatsTrackingCapgoUpdater!

    override func setUp() {
        super.setUp()
        implementation = StatsTrackingCapgoUpdater()
        implementation.setLogger(Logger(withTag: "SessionKeyRequiredTests", options: Logger.Options(level: .silent)))
        implementation.setPublicKey(Fixture.publicKeyPem)
    }

    override func tearDown() {
        implementation.shutdown()
        implementation = nil
        super.tearDown()
    }

    func testDownloadManifestRejectsWhenSessionKeyMissing() {
        let manifest = [ManifestEntry(file_name: "index.html", file_hash: "abc", download_url: "https://example.com/index.html")]

        XCTAssertThrowsError(try implementation.downloadManifest(manifest: manifest, version: "1.0.0", sessionKey: "")) { error in
            XCTAssertEqual((error as NSError).domain, "CapgoUpdater")
            XCTAssertEqual((error as NSError).code, 1)
        }
        XCTAssertTrue(implementation.sentStatsActions.contains("session_key_required"))
    }

    func testDownloadRejectsWhenSessionKeyMissing() {
        let url = URL(string: "https://example.com/update.zip")!

        XCTAssertThrowsError(try implementation.download(url: url, version: "1.0.0", sessionKey: "")) { error in
            XCTAssertEqual((error as NSError).domain, "CapgoUpdater")
            XCTAssertEqual((error as NSError).code, 1)
        }
        XCTAssertTrue(implementation.sentStatsActions.contains("session_key_required"))
    }

    func testDownloadRejectsWhenSessionKeyFormatInvalid() {
        let url = URL(string: "https://example.com/update.zip")!

        XCTAssertThrowsError(try implementation.download(url: url, version: "1.0.0", sessionKey: "invalid-format")) { error in
            XCTAssertEqual((error as NSError).domain, "CapgoUpdater")
            XCTAssertEqual((error as NSError).code, 1)
        }
        XCTAssertTrue(implementation.sentStatsActions.contains("session_key_required"))
    }

    func testIsValidSessionKeyRejectsEmptyComponents() {
        XCTAssertFalse(CryptoCipher.isValidSessionKey(""))
        XCTAssertFalse(CryptoCipher.isValidSessionKey(":"))
        XCTAssertFalse(CryptoCipher.isValidSessionKey("abc:"))
        XCTAssertFalse(CryptoCipher.isValidSessionKey(":xyz"))
        XCTAssertFalse(CryptoCipher.isValidSessionKey("invalid-format"))
        XCTAssertTrue(CryptoCipher.isValidSessionKey("abc:def"))
    }

    func testAutoUpdateRejectsMissingSessionKeyWhenPendingBundleExists() {
        let updater = PendingBundleAutoUpdateCapgoUpdater()
        updater.setLogger(Logger(withTag: "SessionKeyRequiredTests", options: Logger.Options(level: .silent)))
        updater.setPublicKey(Fixture.publicKeyPem)

        let plugin = TestableCapacitorUpdaterPlugin()
        plugin.implementation = updater
        plugin.setAutoUpdateModeForTesting("onlyDownload")
        plugin.setUpdateUrlForTesting("https://example.com/channel")

        plugin.backgroundDownload()

        XCTAssertTrue(updater.sentStatsActions.contains("session_key_required"))
        updater.shutdown()
    }

    func testAutoUpdateBackgroundDownloadRejectsWhenSessionKeyMissing() {
        let updater = AutoUpdateSessionKeyCapgoUpdater()
        updater.setLogger(Logger(withTag: "SessionKeyRequiredTests", options: Logger.Options(level: .silent)))
        updater.setPublicKey(Fixture.publicKeyPem)

        let plugin = TestableCapacitorUpdaterPlugin()
        plugin.implementation = updater
        plugin.setAutoUpdateModeForTesting("onlyDownload")
        plugin.setUpdateUrlForTesting("https://example.com/channel")

        plugin.backgroundDownload()

        XCTAssertTrue(updater.sentStatsActions.contains("session_key_required"))
        updater.shutdown()
    }

    func testAllowsUpdateWhenNoPublicKeyConfigured() throws {
        implementation.setPublicKey("")
        let manifest = [ManifestEntry(file_name: "index.html", file_hash: "abc", download_url: "http://[")]

        // Invalid URL fails fast after the session-key gate, proving the gate did not block.
        XCTAssertThrowsError(try implementation.downloadManifest(manifest: manifest, version: "1.0.0", sessionKey: ""))
        XCTAssertFalse(implementation.sentStatsActions.contains("session_key_required"))
    }
}
