import XCTest
@testable import CapacitorUpdaterPlugin

final class ChecksumRequiredTests: XCTestCase {
    private var implementation: StatsRecordingCapgoUpdater!

    override func setUp() {
        super.setUp()
        implementation = StatsRecordingCapgoUpdater()
        implementation.setLogger(Logger(withTag: "ChecksumRequiredTests", options: Logger.Options(level: .silent)))
        implementation.setPublicKey("")
    }

    override func tearDown() {
        implementation.shutdown()
        implementation = nil
        super.tearDown()
    }

    func testDownloadRejectsWhenChecksumMissing() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/update.zip"))

        XCTAssertThrowsError(try implementation.download(url: url, version: "1.0.0", sessionKey: "", checksum: "")) { error in
            XCTAssertEqual((error as? CapgoCore.Failure)?.code, "checksum_required")
        }
        XCTAssertTrue(implementation.sentStatsActions.contains("checksum_required"))
    }
}
