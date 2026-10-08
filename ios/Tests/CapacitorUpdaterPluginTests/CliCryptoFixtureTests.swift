import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

/// Decrypts bundles encrypted by the real Capgo CLI (native-contract-tests/cli, written by
/// scripts/generate-cli-crypto-fixtures.mjs) through the plugin's own download path.
final class CliCryptoFixtureTests: XCTestCase {
    private struct InstalledFile {
        let path: String
        let sha256: String
    }

    private struct Bundle {
        let id: String
        let zip: Data
        let encrypted: Data
        let sha256: String
        let checksum: String
        let ivSessionKey: String
        let files: [InstalledFile]
    }

    private var root = URL(fileURLWithPath: NSTemporaryDirectory())
    private let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("capgo-cli-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Zip downloads are staged in Documents, which a fresh simulator without a host app may not have yet.
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        }
        CryptoCipher.setLogger(Logger(withTag: "cli-fixture-tests", options: Logger.Options(level: .silent)))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static func fixtureDirectory() throws -> URL {
        let fileManager = FileManager.default
        for start in [URL(fileURLWithPath: fileManager.currentDirectoryPath), URL(fileURLWithPath: #filePath)] {
            var current = start
            while current.path != "/" {
                let candidate = current.appendingPathComponent("native-contract-tests/cli")
                if fileManager.fileExists(atPath: candidate.appendingPathComponent("cli-crypto.json").path) {
                    return candidate
                }
                current.deleteLastPathComponent()
            }
        }
        throw NSError(domain: "CliCryptoFixtureTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "native-contract-tests/cli not found"])
    }

    private func loadFixture() throws -> (publicKey: String, bundles: [Bundle]) {
        let dir = try Self.fixtureDirectory()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("cli-crypto.json")))
        let fixture = try XCTUnwrap(json as? [String: Any])
        let publicKey = try XCTUnwrap(fixture["publicKey"] as? String)
        let entries = try XCTUnwrap(fixture["bundles"] as? [[String: Any]])
        let bundles = try entries.map { entry -> Bundle in
            let files = try XCTUnwrap(entry["files"] as? [[String: Any]]).map { file in
                InstalledFile(path: try XCTUnwrap(file["path"] as? String), sha256: try XCTUnwrap(file["sha256"] as? String))
            }
            return Bundle(
                id: try XCTUnwrap(entry["id"] as? String),
                zip: try Data(contentsOf: dir.appendingPathComponent(try XCTUnwrap(entry["zip"] as? String))),
                encrypted: try Data(contentsOf: dir.appendingPathComponent(try XCTUnwrap(entry["encrypted"] as? String))),
                sha256: try XCTUnwrap(entry["sha256"] as? String),
                checksum: try XCTUnwrap(entry["checksum"] as? String),
                ivSessionKey: try XCTUnwrap(entry["ivSessionKey"] as? String),
                files: files
            )
        }
        XCTAssertFalse(bundles.isEmpty, "fixture has bundles")
        return (publicKey, bundles)
    }

    func testEveryCliEncryptedBundleDecryptsToItsZip() throws {
        let fixture = try loadFixture()
        for bundle in fixture.bundles {
            let file = root.appendingPathComponent("\(bundle.id).zip")
            try bundle.encrypted.write(to: file)

            XCTAssertTrue(CryptoCipher.isValidSessionKey(bundle.ivSessionKey), bundle.id)
            try CryptoCipher.decryptFile(filePath: file, publicKey: fixture.publicKey, sessionKey: bundle.ivSessionKey, version: "1.0.0")
            let expectedChecksum = try CryptoCipher.decryptChecksum(checksum: bundle.checksum, publicKey: fixture.publicKey)

            XCTAssertEqual(try Data(contentsOf: file), bundle.zip, "\(bundle.id): decrypted bytes")
            XCTAssertEqual(expectedChecksum, bundle.sha256, "\(bundle.id): decrypted checksum")
            XCTAssertEqual(CryptoCipher.calcChecksum(filePath: file), expectedChecksum, "\(bundle.id): file checksum")
        }
    }

    /// Serves the CLI-encrypted payload instead of fetching the URL.
    private final class FixtureDownloadCapgoUpdater: CapgoUpdater {
        var payload = Data()

        override func sendStats(action _: String, versionName _: String? = nil, oldVersionName _: String? = "") {}

        override func performDownloadRequest(_ request: URLRequest, label _: String) -> DownloadRequestResult {
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("capgo-cli-fixture-\(UUID().uuidString).zip")
            do {
                try payload.write(to: fileURL)
            } catch {
                return DownloadRequestResult(fileURL: nil, response: nil, error: error, timedOut: false)
            }
            let response = HTTPURLResponse(url: request.url ?? fileURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
            return DownloadRequestResult(fileURL: fileURL, response: response, error: nil, timedOut: false)
        }
    }

    func testDownloadVerifiedInstallsEveryCliEncryptedBundle() throws {
        let fixture = try loadFixture()
        for bundle in fixture.bundles {
            let updater = FixtureDownloadCapgoUpdater()
            updater.setLogger(Logger(withTag: "cli-fixture-tests", options: Logger.Options(level: .silent)))
            updater.setPublicKey(fixture.publicKey)
            updater.payload = bundle.encrypted
            defer { updater.shutdown() }

            // The raw update response values: encrypted checksum and ivSessionKey from the CLI.
            let installed = try updater.downloadVerified(
                url: root.appendingPathComponent("\(bundle.id).zip"),
                version: "9.9.9-cli-\(bundle.id)",
                sessionKey: bundle.ivSessionKey,
                expectedChecksum: bundle.checksum
            )
            defer { _ = updater.delete(id: installed.getId()) }

            XCTAssertEqual(installed.getChecksum(), bundle.sha256, bundle.id)
            let bundleDir = libraryDir.appendingPathComponent("NoCloud/ionic_built_snapshots").appendingPathComponent(installed.getId())
            for file in bundle.files {
                let path = bundleDir.appendingPathComponent(file.path)
                XCTAssertEqual(CryptoCipher.calcChecksum(filePath: path), file.sha256, "\(bundle.id): \(file.path)")
            }
        }
    }
}
