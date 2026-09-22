import XCTest
@testable import CapacitorUpdaterPlugin

final class ChecksumRequiredTests: XCTestCase {
    private final class StatsTrackingCapgoUpdater: CapgoUpdater {
        var sentStatsActions: [String] = []

        override func sendStats(action: String, versionName: String? = nil, oldVersionName: String? = "") {
            sentStatsActions.append(action)
        }
    }

    private final class AutoUpdateChecksumCapgoUpdater: StatsTrackingCapgoUpdater {
        override func getLatest(url: URL, channel: String?, appIdOverride: String? = nil) -> AppVersion {
            let latest = AppVersion()
            latest.version = "2.0.0"
            latest.url = "https://example.com/update.zip"
            latest.checksum = ""
            return latest
        }

        override func getCurrentBundle() -> BundleInfo {
            BundleInfo(id: "current-id", version: "1.0.0", status: .SUCCESS, downloaded: Date(), checksum: "abc")
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
        implementation.setLogger(Logger(withTag: "ChecksumRequiredTests", options: Logger.Options(level: .silent)))
        implementation.setPublicKey("")
    }

    override func tearDown() {
        implementation.shutdown()
        implementation = nil
        super.tearDown()
    }

    func testDownloadBundleRejectsWhenChecksumMissing() {
        let plugin = TestableCapacitorUpdaterPlugin()
        plugin.implementation = implementation

        XCTAssertThrowsError(
            try plugin.downloadBundleForTesting(
                urlString: "https://example.com/update.zip",
                version: "1.0.0",
                sessionKey: "",
                checksum: "",
                manifestEntries: nil
            )
        )
        XCTAssertTrue(implementation.sentStatsActions.contains("checksum_required"))
    }

    func testDownloadBundleRejectsWhenChecksumMismatch() throws {
        let plugin = TestableCapacitorUpdaterPlugin()
        let downloaded = BundleInfo(
            id: "downloaded-id",
            version: "1.0.0",
            status: .PENDING,
            downloaded: Date(),
            checksum: "actual-checksum"
        )
        let downloadingImplementation = DownloadStubCapgoUpdater(downloadedBundle: downloaded)
        downloadingImplementation.setLogger(Logger(withTag: "ChecksumRequiredTests", options: Logger.Options(level: .silent)))
        plugin.implementation = downloadingImplementation

        XCTAssertThrowsError(
            try plugin.downloadBundleForTesting(
                urlString: "https://example.com/update.zip",
                version: "1.0.0",
                sessionKey: "",
                checksum: "expected-checksum",
                manifestEntries: nil
            )
        )
        XCTAssertTrue(downloadingImplementation.sentStatsActions.contains("checksum_fail"))
        downloadingImplementation.shutdown()
    }

    func testDownloadBundleAcceptsWhenChecksumMatches() throws {
        let plugin = TestableCapacitorUpdaterPlugin()
        let downloaded = BundleInfo(
            id: "downloaded-id",
            version: "1.0.0",
            status: .PENDING,
            downloaded: Date(),
            checksum: "matching-checksum"
        )
        let downloadingImplementation = DownloadStubCapgoUpdater(downloadedBundle: downloaded)
        downloadingImplementation.setLogger(Logger(withTag: "ChecksumRequiredTests", options: Logger.Options(level: .silent)))
        plugin.implementation = downloadingImplementation

        let bundle = try plugin.downloadBundleForTesting(
            urlString: "https://example.com/update.zip",
            version: "1.0.0",
            sessionKey: "",
            checksum: "matching-checksum",
            manifestEntries: nil
        )

        XCTAssertEqual(bundle.getChecksum(), "matching-checksum")
        XCTAssertFalse(downloadingImplementation.sentStatsActions.contains("checksum_required"))
        XCTAssertFalse(downloadingImplementation.sentStatsActions.contains("checksum_fail"))
        downloadingImplementation.shutdown()
    }

    func testAutoUpdateBackgroundDownloadRejectsWhenChecksumMissing() {
        let updater = AutoUpdateChecksumCapgoUpdater()
        updater.setLogger(Logger(withTag: "ChecksumRequiredTests", options: Logger.Options(level: .silent)))

        let plugin = TestableCapacitorUpdaterPlugin()
        plugin.implementation = updater
        plugin.setAutoUpdateModeForTesting("onlyDownload")
        plugin.setUpdateUrlForTesting("https://example.com/channel")

        plugin.backgroundDownload()

        XCTAssertTrue(updater.sentStatsActions.contains("checksum_required"))
        updater.shutdown()
    }
}

private final class DownloadStubCapgoUpdater: ChecksumRequiredTests.StatsTrackingCapgoUpdater {
    private let downloadedBundle: BundleInfo

    init(downloadedBundle: BundleInfo) {
        self.downloadedBundle = downloadedBundle
        super.init()
    }

    override func download(url: URL, version: String, sessionKey: String, link: String? = nil, comment: String? = nil) throws -> BundleInfo {
        downloadedBundle
    }
}
