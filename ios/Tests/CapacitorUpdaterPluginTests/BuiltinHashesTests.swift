import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

private final class TestableCapgoUpdater: CapgoUpdater {
    var builtinFolderOverride = FileManager.default.temporaryDirectory.appendingPathComponent("builtin-hashes-\(UUID().uuidString)")

    override func builtinFolderURL() -> URL {
        builtinFolderOverride
    }
}

final class BuiltinHashesTests: XCTestCase {
    private var implementation: TestableCapgoUpdater!
    private var builtinFolder: URL {
        implementation.builtinFolderOverride
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        CryptoCipher.setLogger(Logger(withTag: "BuiltinHashesTests", options: Logger.Options(level: .silent)))
        implementation = TestableCapgoUpdater()
        try FileManager.default.createDirectory(at: builtinFolder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: builtinFolder)
        implementation = nil
        CryptoCipher.setLogger(Logger(withTag: "TestLogger"))
        super.tearDown()
    }

    private func writeHashTable(files: [String: String], sizes: [String: Int64]? = nil) throws {
        var filesPayload: [String: Any] = [:]
        for (key, hash) in files {
            if let size = sizes?[key] {
                filesPayload[key] = ["sha256": hash, "size": size]
            } else {
                let fileURL = builtinFolder.appendingPathComponent(key)
                if FileManager.default.fileExists(atPath: fileURL.path),
                   let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    filesPayload[key] = ["sha256": hash, "size": Int64(fileSize)]
                } else {
                    filesPayload[key] = ["sha256": hash]
                }
            }
        }
        let payload: [String: Any] = ["files": filesPayload]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: builtinFolder.appendingPathComponent(CapgoUpdater.builtinHashesFileName))
    }

    func testGetMissingBundleFilesFallsBackToHashingWhenTableSizeStale() throws {
        let content = "stale size row \(UUID().uuidString)"
        let fileURL = builtinFolder.appendingPathComponent("index.html")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        let hash = CryptoCipher.calcChecksum(filePath: fileURL)
        let staleSize = Int64((try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) + 99)
        try writeHashTable(files: ["index.html": hash], sizes: ["index.html": staleSize])
        let manifest = [
            ManifestEntry(file_name: "index.html", file_hash: hash, download_url: nil)
        ]
        XCTAssertTrue(implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "").isEmpty)
    }

    func testGetMissingBundleFilesUsesHashTableWithoutReadingBuiltinFile() throws {
        let content = "table match \(UUID().uuidString)"
        let fileURL = builtinFolder.appendingPathComponent("index.html")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        let expectedHash = String(repeating: "a", count: 64)
        try writeHashTable(files: ["index.html": expectedHash])
        let manifest = [
            ManifestEntry(file_name: "index.html", file_hash: expectedHash, download_url: nil)
        ]
        XCTAssertTrue(implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "").isEmpty)
    }

    func testGetMissingBundleFilesReportsMissingWhenTableMatchesButFileAbsent() throws {
        let expectedHash = String(repeating: "a", count: 64)
        try writeHashTable(files: ["index.html": expectedHash])
        let manifest = [
            ManifestEntry(file_name: "index.html", file_hash: expectedHash, download_url: nil)
        ]
        XCTAssertEqual(implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "").count, 1)
    }

    func testGetMissingBundleFilesReportsMissingWhenHashTableDisagrees() throws {
        let content = "table mismatch \(UUID().uuidString)"
        let fileURL = builtinFolder.appendingPathComponent("index.html")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        let manifestHash = CryptoCipher.calcChecksum(filePath: fileURL)
        let tableHash = String(repeating: "b", count: 64)
        try writeHashTable(files: ["index.html": tableHash])
        let manifest = [
            ManifestEntry(file_name: "index.html", file_hash: manifestHash, download_url: nil)
        ]
        XCTAssertEqual(implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "").count, 1)
    }

    func testGetMissingBundleFilesFallsBackToHashingWhenPathNotInTable() throws {
        let content = "fallback content \(UUID().uuidString)"
        let fileURL = builtinFolder.appendingPathComponent("app.js")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        let hash = CryptoCipher.calcChecksum(filePath: fileURL)
        try writeHashTable(files: ["other.js": hash])
        let manifest = [
            ManifestEntry(file_name: "app.js", file_hash: hash, download_url: nil)
        ]
        XCTAssertTrue(implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "").isEmpty)
    }

    func testGetMissingBundleFilesFallsBackWhenTableEntryIsMalformed() throws {
        let content = "malformed table \(UUID().uuidString)"
        let fileURL = builtinFolder.appendingPathComponent("index.html")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        let hash = CryptoCipher.calcChecksum(filePath: fileURL)
        try writeHashTable(files: ["index.html": "not-a-sha256"])
        let manifest = [
            ManifestEntry(file_name: "index.html", file_hash: hash, download_url: nil)
        ]
        XCTAssertTrue(implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "").isEmpty)
    }

    func testGetMissingBundleFilesFallsBackWhenHashTableMissingOrMalformed() throws {
        let content = "no table \(UUID().uuidString)"
        let fileURL = builtinFolder.appendingPathComponent("index.html")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        let hash = CryptoCipher.calcChecksum(filePath: fileURL)
        try "{ not json".write(to: builtinFolder.appendingPathComponent(CapgoUpdater.builtinHashesFileName), atomically: true, encoding: .utf8)
        let manifest = [
            ManifestEntry(file_name: "index.html", file_hash: hash, download_url: nil)
        ]
        XCTAssertTrue(implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "").isEmpty)
    }

    func testBuiltinHashesTableReadOnceAcrossManyLookupsAndUpdates() throws {
        let contentA = "entry a \(UUID().uuidString)"
        let contentB = "entry b \(UUID().uuidString)"
        let fileA = builtinFolder.appendingPathComponent("index.html")
        let fileB = builtinFolder.appendingPathComponent("app.js")
        try contentA.write(to: fileA, atomically: true, encoding: .utf8)
        try contentB.write(to: fileB, atomically: true, encoding: .utf8)
        let hashA = String(repeating: "d", count: 64)
        let hashB = String(repeating: "e", count: 64)
        try writeHashTable(files: ["index.html": hashA, "app.js": hashB])

        for i in 0..<12 {
            let manifest = [
                ManifestEntry(file_name: "index.html", file_hash: hashA, download_url: nil),
                ManifestEntry(file_name: "app.js", file_hash: hashB, download_url: nil)
            ]
            if i.isMultiple(of: 2) {
                XCTAssertTrue(implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "").isEmpty)
            } else {
                _ = implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "")
            }
        }

        XCTAssertEqual(implementation.builtinHashesTableLoadCount, 1)
    }

    func testBuiltinHashesTableReadOnceWhenMissingOrMalformed() throws {
        let content = "no valid table \(UUID().uuidString)"
        let fileURL = builtinFolder.appendingPathComponent("index.html")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        let hash = CryptoCipher.calcChecksum(filePath: fileURL)
        try "{ not json".write(to: builtinFolder.appendingPathComponent(CapgoUpdater.builtinHashesFileName), atomically: true, encoding: .utf8)

        for _ in 0..<8 {
            let manifest = [
                ManifestEntry(file_name: "index.html", file_hash: hash, download_url: nil)
            ]
            XCTAssertTrue(implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "").isEmpty)
        }

        XCTAssertEqual(implementation.builtinHashesTableLoadCount, 1)
    }
}
