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

    private func writeHashTable(files: [String: String]) throws {
        let payload: [String: Any] = ["files": files]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: builtinFolder.appendingPathComponent(CapgoUpdater.builtinHashesFileName))
    }

    func testGetMissingBundleFilesUsesHashTableWithoutReadingBuiltinFile() throws {
        let expectedHash = String(repeating: "a", count: 64)
        try writeHashTable(files: ["index.html": expectedHash])
        let manifest = [
            ManifestEntry(file_name: "index.html", file_hash: expectedHash, download_url: nil)
        ]
        XCTAssertTrue(implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "").isEmpty)
    }

    func testGetMissingBundleFilesReportsMissingWhenHashTableDisagrees() throws {
        let tableHash = String(repeating: "b", count: 64)
        let manifestHash = String(repeating: "c", count: 64)
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
}
