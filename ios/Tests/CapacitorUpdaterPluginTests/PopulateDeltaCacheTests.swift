import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

/// Overrides builtinFolderURL() with a writable temp directory — the real app
/// bundle (Bundle.main) is read-only at test-runtime, so tests can't write
/// fixture files there directly.
private final class TestableCapgoUpdater: CapgoUpdater {
    var builtinFolderOverride = FileManager.default.temporaryDirectory.appendingPathComponent("populate-delta-cache-builtin-\(UUID().uuidString)")

    override func builtinFolderURL() -> URL {
        builtinFolderOverride
    }
}

final class PopulateDeltaCacheTests: XCTestCase {
    private var implementation: TestableCapgoUpdater!
    private var bundleId: String!
    private var bundleDir: URL!
    private var registeredCacheFiles: [URL] = []
    private let cacheFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("capgo_downloads")
    private var builtinFolder: URL {
        implementation.builtinFolderOverride
    }

    // Loaded from the same RSA fixture native-contract-tests/crypto-rsa.json uses
    // (see RsaContractTests.swift), so the encrypted-manifest path is exercised
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

    override func setUp() {
        super.setUp()
        CryptoCipher.setLogger(Logger(withTag: "PopulateDeltaCacheTests", options: Logger.Options(level: .silent)))
        implementation = TestableCapgoUpdater()
        bundleId = "delta-cache-\(UUID().uuidString)"
        bundleDir = implementation.getBundleDirectory(id: bundleId)
        try? FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: bundleDir)
        try? FileManager.default.removeItem(at: builtinFolder)
        for file in registeredCacheFiles {
            try? FileManager.default.removeItem(at: file)
        }
        registeredCacheFiles = []
        implementation = nil
        // CryptoCipher's logger is shared/static with no getter to snapshot the prior
        // value, so restore a normal (non-silent) default rather than leaving other
        // test suites silenced by this one.
        CryptoCipher.setLogger(Logger(withTag: "TestLogger"))
        super.tearDown()
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

    // MARK: - manifestHashLookup

    func testManifestHashLookupStripsBrotliSuffixAndReturnsPlainHash() {
        let manifest = [
            ManifestEntry(file_name: "assets/app.js.br", file_hash: "plainhash", download_url: nil)
        ]

        let lookup = implementation.manifestHashLookup(manifest: manifest, sessionKey: "")

        XCTAssertEqual(lookup["assets/app.js"]?.hash, "plainhash")
        // The original (unstripped) manifest name must be preserved — it's what the
        // built-in bundle actually stores the file under.
        XCTAssertEqual(lookup["assets/app.js"]?.originalFileName, "assets/app.js.br")
        XCTAssertNil(lookup["assets/app.js.br"])
    }

    func testManifestHashLookupDecryptsEncryptedManifestHashes() {
        let (checksumHex, decryptedHex) = Fixture.firstDecryptChecksumCase
        implementation.setPublicKey(Fixture.publicKeyPem)
        let manifest = [
            ManifestEntry(file_name: "index.html", file_hash: checksumHex, download_url: nil)
        ]

        let lookup = implementation.manifestHashLookup(manifest: manifest, sessionKey: "session-key")

        XCTAssertEqual(lookup["index.html"]?.hash, decryptedHex)
    }

    func testManifestHashLookupSkipsEntriesMissingFileNameOrHash() {
        let manifest = [
            ManifestEntry(file_name: nil, file_hash: "hash", download_url: nil),
            ManifestEntry(file_name: "no-hash.js", file_hash: nil, download_url: nil)
        ]

        XCTAssertTrue(implementation.manifestHashLookup(manifest: manifest, sessionKey: "").isEmpty)
    }

    // MARK: - populateDeltaCache: (a) reuse manifest hashes instead of re-hashing

    func testPopulateDeltaCacheReusesManifestHashInsteadOfRecomputing() throws {
        let fileURL = try write("hello world \(bundleId!)", named: "app.js", in: bundleDir)
        let realHash = CryptoCipher.calcChecksum(filePath: fileURL)
        let manifestHash = "deliberately-different-\(realHash)"
        let manifest = [
            ManifestEntry(file_name: "app.js", file_hash: manifestHash, download_url: nil)
        ]
        let manifestCacheFile = expectedCacheFile(hash: manifestHash, name: "app.js")
        let realCacheFile = expectedCacheFile(hash: realHash, name: "app.js")

        implementation.populateDeltaCache(for: bundleId, manifest: manifest, sessionKey: "")

        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestCacheFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: realCacheFile.path))
    }

    func testPopulateDeltaCacheFallsBackToRealHashWhenNoManifestEntry() throws {
        let fileURL = try write("hello world \(bundleId!)", named: "app.js", in: bundleDir)
        let realHash = CryptoCipher.calcChecksum(filePath: fileURL)
        let realCacheFile = expectedCacheFile(hash: realHash, name: "app.js")

        implementation.populateDeltaCache(for: bundleId)

        XCTAssertTrue(FileManager.default.fileExists(atPath: realCacheFile.path))
    }

    // MARK: - populateDeltaCache: (b) skip caching builtin-origin files

    func testPopulateDeltaCacheSkipsFilesAlreadyAvailableFromBuiltin() throws {
        let content = "shared builtin content \(bundleId!)"
        let fileURL = try write(content, named: "shared.js", in: bundleDir)
        let realHash = CryptoCipher.calcChecksum(filePath: fileURL)
        try write(content, named: "shared.js", in: builtinFolder)
        let cacheFile = expectedCacheFile(hash: realHash, name: "shared.js")

        implementation.populateDeltaCache(for: bundleId)

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    func testPopulateDeltaCacheStillCachesFilesNotPresentInBuiltin() throws {
        let fileURL = try write("only in this bundle \(bundleId!)", named: "new.js", in: bundleDir)
        let realHash = CryptoCipher.calcChecksum(filePath: fileURL)
        let cacheFile = expectedCacheFile(hash: realHash, name: "new.js")

        implementation.populateDeltaCache(for: bundleId)

        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    /// Regression test: the built-in bundle stores brotli manifest entries under
    /// their original (`.br`-suffixed) name, while the extracted bundle file on disk
    /// is always named without it. The builtin lookup must resolve against the
    /// manifest's original name, not the extracted file's own path, or this match
    /// silently never fires for any compressed asset.
    func testPopulateDeltaCacheSkipsBrotliFilesAlreadyAvailableFromBuiltin() throws {
        let content = "shared builtin content \(bundleId!)"
        let extractedFileURL = try write(content, named: "app.js", in: bundleDir.appendingPathComponent("assets"))
        let realHash = CryptoCipher.calcChecksum(filePath: extractedFileURL)
        try write(content, named: "app.js.br", in: builtinFolder.appendingPathComponent("assets"))
        let manifest = [
            ManifestEntry(file_name: "assets/app.js.br", file_hash: realHash, download_url: nil)
        ]
        let cacheFile = expectedCacheFile(hash: realHash, name: "app.js")

        implementation.populateDeltaCache(for: bundleId, manifest: manifest, sessionKey: "")

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
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

        let missing = implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "")

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

        let missing = implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "")

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

        let missing = implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "")

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

        let missing = implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "")

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

        let missing = implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "")

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

        let missing = implementation.getMissingBundleFiles(manifest: manifest, sessionKey: "")

        XCTAssertTrue(missing.isEmpty)
    }
}

final class IoBufferSizeTests: XCTestCase {
    func testChecksumBufferStaysSmallOnLowRamAndFullOnFlagship() {
        XCTAssertEqual(CryptoCipher.checksumBufferBytes(3 * 1024 * 1024 * 1024), 64 * 1024)
        XCTAssertEqual(CryptoCipher.checksumBufferBytes(4 * 1024 * 1024 * 1024), 1024 * 1024)
        XCTAssertEqual(CryptoCipher.checksumBufferBytes(8 * 1024 * 1024 * 1024), 5 * 1024 * 1024)
        XCTAssertEqual(CryptoCipher.checksumBufferBytes(0), 5 * 1024 * 1024)
    }

    func testCopyBufferStaysSmallOnLowRamAndFullOnFlagship() {
        XCTAssertEqual(CryptoCipher.copyBufferBytes(3 * 1024 * 1024 * 1024), 64 * 1024)
        XCTAssertEqual(CryptoCipher.copyBufferBytes(4 * 1024 * 1024 * 1024), 1024 * 1024)
        XCTAssertEqual(CryptoCipher.copyBufferBytes(0), 1024 * 1024)
    }
}
