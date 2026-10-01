import CryptoKit
import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

/// Points the builtin folder at a writable temp directory — the real app
/// bundle (Bundle.main) is read-only at test-runtime, so tests can't write
/// fixture files there directly.
private final class TestableCapgoUpdater: StatsRecordingCapgoUpdater {
    override init() {
        super.init()
        builtinFolderOverride = FileManager.default.temporaryDirectory.appendingPathComponent("populate-delta-cache-builtin-\(UUID().uuidString)")
    }
}

final class PopulateDeltaCacheTests: XCTestCase {
    private var implementation: TestableCapgoUpdater!
    private var bundleId: String!
    private var bundleDir: URL!
    private var registeredCacheFiles: [URL] = []
    private let cacheFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("capgo_downloads")
    private var builtinFolder: URL {
        implementation.builtinFolderURL()
    }

    // Loaded from the same RSA fixture native-contract-tests/crypto-rsa.json uses
    // (see core/tests/contract.rs), so the encrypted-manifest path is exercised
    // against real contract data rather than an invented key/ciphertext pair.
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

        static var firstDecryptChecksumCase: (checksumHex: String, decryptedHex: String) {
            guard let cases = contract["decryptChecksum"] as? [[String: Any]],
                  let first = cases.first,
                  let input = first["input"] as? [String: Any],
                  let expect = first["expect"] as? [String: Any],
                  let checksumHex = input["checksumHex"] as? String,
                  let decryptedHex = expect["decryptedHex"] as? String else {
                XCTFail("Missing decryptChecksum fixture case")
                return ("", "")
            }
            return (checksumHex, decryptedHex)
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
            throw NSError(domain: "PopulateDeltaCacheTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "crypto-rsa.json not found"])
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        implementation = TestableCapgoUpdater()
        bundleId = "delta-cache-\(UUID().uuidString)"
        bundleDir = try implementation.bundleDirectory(id: bundleId)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if implementation != nil {
            try? FileManager.default.removeItem(at: bundleDir)
        }
        try? FileManager.default.removeItem(at: builtinFolder)
        for file in registeredCacheFiles {
            try? FileManager.default.removeItem(at: file)
        }
        registeredCacheFiles = []
        implementation = nil
        super.tearDown()
    }

    /// Lowercase hex SHA-256 of a file (the delta cache key).
    private func sha256(_ file: URL) -> String {
        guard let data = try? Data(contentsOf: file) else {
            return ""
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum FixtureError: Error {
        case writeFailed(String)
    }

    @discardableResult
    private func write(_ content: String, named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        guard let data = content.data(using: .utf8) else {
            throw FixtureError.writeFailed("Could not encode fixture content for \(name)")
        }
        try data.write(to: url)
        return url
    }

    /// Computes the cache path for (hash, name), clears any stale entry left over from
    /// an unrelated run (content/hash is deterministic, so paths can collide across
    /// runs), and registers it for teardown cleanup regardless of test outcome.
    private func expectedCacheFile(hash: String, name: String) -> URL {
        let file = cacheFolder.appendingPathComponent("\(hash)_\(name)")
        try? FileManager.default.removeItem(at: file)
        registeredCacheFiles.append(file)
        return file
    }

    // MARK: - populateDeltaCache

    func testPopulateDeltaCacheCachesBundleFilesByContentHash() throws {
        let fileURL = try write("hello world \(bundleId!)", named: "app.js", in: bundleDir)
        let realHash = sha256(fileURL)
        let realCacheFile = expectedCacheFile(hash: realHash, name: "app.js")

        try implementation.populateDeltaCache(for: bundleId)

        XCTAssertTrue(FileManager.default.fileExists(atPath: realCacheFile.path))
    }

    // MARK: - populateDeltaCache: (b) skip caching builtin-origin files

    func testPopulateDeltaCacheSkipsFilesAlreadyAvailableFromBuiltin() throws {
        let content = "shared builtin content \(bundleId!)"
        let fileURL = try write(content, named: "shared.js", in: bundleDir)
        let realHash = sha256(fileURL)
        try write(content, named: "shared.js", in: builtinFolder)
        let cacheFile = expectedCacheFile(hash: realHash, name: "shared.js")

        try implementation.populateDeltaCache(for: bundleId)

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    func testPopulateDeltaCacheStillCachesFilesNotPresentInBuiltin() throws {
        let fileURL = try write("only in this bundle \(bundleId!)", named: "new.js", in: bundleDir)
        let realHash = sha256(fileURL)
        let cacheFile = expectedCacheFile(hash: realHash, name: "new.js")

        try implementation.populateDeltaCache(for: bundleId)

        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    // MARK: - getMissingBundleFiles: trust hash-named cache without re-reading

    func testGetMissingBundleFilesTreatsHashNamedCacheAsReusable() throws {
        let hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let cacheFile = expectedCacheFile(hash: hash, name: "app.js")
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        // Content does not need to match the hash: the filename is the trust source
        // (checksum was verified when the cache entry was written).
        try "not-the-hashed-bytes".write(to: cacheFile, atomically: true, encoding: .utf8)
        let manifest = [
            ManifestEntry(file_name: "app.js", file_hash: hash, download_url: nil)
        ]

        let missing = try implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "")

        XCTAssertTrue(missing.isEmpty)
    }

    func testGetMissingBundleFilesIgnoresEmptyHashNamedCache() throws {
        let hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let cacheFile = expectedCacheFile(hash: hash, name: "app.js")
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        try Data().write(to: cacheFile)
        let manifest = [
            ManifestEntry(file_name: "app.js", file_hash: hash, download_url: nil)
        ]

        let missing = try implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "")

        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(missing.first?.file_name, "app.js")
    }

    func testGetMissingBundleFilesReusesEmptyFileForEmptySha256() throws {
        let hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let cacheFile = expectedCacheFile(hash: hash, name: "empty.txt")
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        try Data().write(to: cacheFile)
        let manifest = [
            ManifestEntry(file_name: "empty.txt", file_hash: hash, download_url: nil)
        ]

        let missing = try implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "")

        XCTAssertTrue(missing.isEmpty)
    }

    func testGetMissingBundleFilesRejectsUnsafeCacheHash() throws {
        let hash = "../evil"
        let cacheFile = expectedCacheFile(hash: hash, name: "app.js")
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        try "payload".write(to: cacheFile, atomically: true, encoding: .utf8)
        let manifest = [
            ManifestEntry(file_name: "app.js", file_hash: hash, download_url: nil)
        ]

        let missing = try implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "")

        XCTAssertEqual(missing.count, 1)
    }

    func testGetMissingBundleFilesDoesNotTrustCrc32CacheHash() throws {
        let hash = "deadbeef"
        let cacheFile = expectedCacheFile(hash: hash, name: "app.js")
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        try "payload".write(to: cacheFile, atomically: true, encoding: .utf8)
        let manifest = [
            ManifestEntry(file_name: "app.js", file_hash: hash, download_url: nil)
        ]

        let missing = try implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "")

        XCTAssertEqual(missing.count, 1)
    }

    func testGetMissingBundleFilesTreatsLegacyBrotliCacheNameAsReusable() throws {
        let hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let cacheFile = expectedCacheFile(hash: hash, name: "app.js.br")
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        try "legacy-brotli-cache".write(to: cacheFile, atomically: true, encoding: .utf8)
        let manifest = [
            ManifestEntry(file_name: "app.js.br", file_hash: hash, download_url: nil)
        ]

        let missing = try implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "")

        XCTAssertTrue(missing.isEmpty)
    }
}

extension PopulateDeltaCacheTests {
    func testGetMissingBundleFilesReusesUncompressedBuiltinForBrotliEntry() throws {
        let testId = try XCTUnwrap(bundleId)
        let name = "\(testId).js"
        let source = try write("builtin \(testId)", named: name, in: builtinFolder.appendingPathComponent("assets"))
        let hash = sha256(source)
        let manifest = [ManifestEntry(file_name: "assets/\(name).br", file_hash: hash, download_url: nil)]

        XCTAssertTrue(try implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "").isEmpty)

        // A decoded filename match alone must not bypass checksum verification.
        try "different content".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertEqual(try implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "").count, 1)
    }

    func testDownloadManifestReusesSignedUncompressedBuiltinForBrotliEntry() throws {
        implementation.setLogger(Logger(withTag: "BrotliBuiltinTest", options: Logger.Options(level: .silent)))
        try implementation.setPublicKey(Fixture.publicKeyPem)
        let name = "\(try XCTUnwrap(bundleId)).js"
        let source = try write("", named: name, in: builtinFolder.appendingPathComponent("assets"))
        let (signedHash, plainHash) = Fixture.firstDecryptChecksumCase
        XCTAssertEqual(sha256(source), plainHash)
        let manifest = [ManifestEntry(
            file_name: "assets/\(name).br",
            file_hash: signedHash,
            // Invalid URL makes any attempted download fail immediately: this must reuse builtin.
            download_url: "http://["
        )]

        // Only checksum recovery is needed when builtin matches; no file/session decryption occurs.
        let result = try implementation.downloadManifest(manifest: manifest, version: "1.0.0", sessionKey: "a:b")
        let id = try XCTUnwrap(result["id"] as? String)
        defer {
            implementation.deleteBundle(id: id)
            implementation.shutdown()
        }
        let destination = try implementation.bundleDirectory(id: id)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("assets/\(name)")), Data())
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("assets/\(name).br").path))
    }

    func testMissingBrotliEntryCannotReuseFileOutsideBuiltin() throws {
        let name = "\(try XCTUnwrap(bundleId))-outside.js"
        let source = try write("outside", named: name, in: builtinFolder.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: source) }
        let hash = sha256(source)
        let manifest = [ManifestEntry(file_name: "../\(name).br", file_hash: hash, download_url: nil)]

        XCTAssertEqual(try implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "").count, 1)
    }
}
