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
        implementation = nil
        super.tearDown()
    }

    private func write(_ content: String, named name: String, in directory: URL) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try? content.data(using: .utf8)?.write(to: url)
        return url
    }

    private func cacheFile(hash: String, name: String) -> URL {
        cacheFolder.appendingPathComponent("\(hash)_\(name)")
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

    func testPopulateDeltaCacheReusesManifestHashInsteadOfRecomputing() {
        let fileURL = write("hello world", named: "app.js", in: bundleDir)
        let realHash = CryptoCipher.calcChecksum(filePath: fileURL)
        let manifestHash = "deliberately-different-\(realHash)"
        let manifest = [
            ManifestEntry(file_name: "app.js", file_hash: manifestHash, download_url: nil)
        ]

        implementation.populateDeltaCache(for: bundleId, manifest: manifest, sessionKey: "")

        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile(hash: manifestHash, name: "app.js").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile(hash: realHash, name: "app.js").path))

        try? FileManager.default.removeItem(at: cacheFile(hash: manifestHash, name: "app.js"))
    }

    func testPopulateDeltaCacheFallsBackToRealHashWhenNoManifestEntry() {
        let fileURL = write("hello world", named: "app.js", in: bundleDir)
        let realHash = CryptoCipher.calcChecksum(filePath: fileURL)

        implementation.populateDeltaCache(for: bundleId)

        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile(hash: realHash, name: "app.js").path))

        try? FileManager.default.removeItem(at: cacheFile(hash: realHash, name: "app.js"))
    }

    // MARK: - populateDeltaCache: (b) skip caching builtin-origin files

    func testPopulateDeltaCacheSkipsFilesAlreadyAvailableFromBuiltin() {
        let content = "shared builtin content"
        let fileURL = write(content, named: "shared.js", in: bundleDir)
        let realHash = CryptoCipher.calcChecksum(filePath: fileURL)
        _ = write(content, named: "shared.js", in: builtinFolder)
        let expectedCacheFile = cacheFile(hash: realHash, name: "shared.js")
        // Guard against a stale cache entry left over from an unrelated run
        // (content/hash is deterministic, so the path can collide across runs).
        try? FileManager.default.removeItem(at: expectedCacheFile)

        implementation.populateDeltaCache(for: bundleId)

        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedCacheFile.path))

        try? FileManager.default.removeItem(at: expectedCacheFile)
    }

    func testPopulateDeltaCacheStillCachesFilesNotPresentInBuiltin() {
        let fileURL = write("only in this bundle", named: "new.js", in: bundleDir)
        let realHash = CryptoCipher.calcChecksum(filePath: fileURL)

        implementation.populateDeltaCache(for: bundleId)

        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile(hash: realHash, name: "new.js").path))

        try? FileManager.default.removeItem(at: cacheFile(hash: realHash, name: "new.js"))
    }

    /// Regression test: the built-in bundle stores brotli manifest entries under
    /// their original (`.br`-suffixed) name, while the extracted bundle file on disk
    /// is always named without it. The builtin lookup must resolve against the
    /// manifest's original name, not the extracted file's own path, or this match
    /// silently never fires for any compressed asset.
    func testPopulateDeltaCacheSkipsBrotliFilesAlreadyAvailableFromBuiltin() {
        let content = "shared builtin content"
        let extractedFileURL = write(content, named: "app.js", in: bundleDir.appendingPathComponent("assets"))
        let realHash = CryptoCipher.calcChecksum(filePath: extractedFileURL)
        _ = write(content, named: "app.js.br", in: builtinFolder.appendingPathComponent("assets"))
        let manifest = [
            ManifestEntry(file_name: "assets/app.js.br", file_hash: realHash, download_url: nil)
        ]
        let expectedCacheFile = cacheFile(hash: realHash, name: "app.js")
        try? FileManager.default.removeItem(at: expectedCacheFile)

        implementation.populateDeltaCache(for: bundleId, manifest: manifest, sessionKey: "")

        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedCacheFile.path))

        try? FileManager.default.removeItem(at: expectedCacheFile)
    }
}