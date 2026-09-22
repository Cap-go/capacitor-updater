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
            var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            while true {
                let candidate = current.appendingPathComponent("native-contract-tests/crypto-rsa.json")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path {
                    throw NSError(domain: "SessionKeyRequiredTests", code: 1)
                }
                current = parent
            }
        }
    }

    private final class StatsTrackingCapgoUpdater: CapgoUpdater {
        var sentStatsActions: [String] = []

        override func sendStats(action: String, versionName: String? = nil, oldVersionName: String? = "") {
            sentStatsActions.append(action)
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
            XCTAssertEqual((error as NSError).localizedDescription, "Session key required when public key is present")
        }
        XCTAssertTrue(implementation.sentStatsActions.contains("session_key_required"))
    }

    func testDownloadRejectsWhenSessionKeyMissing() {
        let url = URL(string: "https://example.com/update.zip")!

        XCTAssertThrowsError(try implementation.download(url: url, version: "1.0.0", sessionKey: "")) { error in
            XCTAssertEqual((error as NSError).localizedDescription, "Session key required when public key is present")
        }
        XCTAssertTrue(implementation.sentStatsActions.contains("session_key_required"))
    }

    func testAllowsUpdateWhenNoPublicKeyConfigured() throws {
        implementation.setPublicKey("")
        let manifest = [ManifestEntry(file_name: "index.html", file_hash: "abc", download_url: "http://[")]

        // Invalid URL fails fast after the session-key gate, proving the gate did not block.
        XCTAssertThrowsError(try implementation.downloadManifest(manifest: manifest, version: "1.0.0", sessionKey: ""))
        XCTAssertFalse(implementation.sentStatsActions.contains("session_key_required"))
    }
}
