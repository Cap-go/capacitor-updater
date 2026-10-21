import CommonCrypto
import CryptoKit
import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

/// Regression tests for the bundle install gates: checksum before extraction, zip symlinks, strict AES.
final class BundleHardeningTests: XCTestCase {
    private var root = URL(fileURLWithPath: NSTemporaryDirectory())
    private let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("capgo-hardening-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Zip downloads are staged in Documents, which a fresh simulator without a host app may not have yet.
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        }
        CryptoCipher.setLogger(Logger(withTag: "hardening-tests", options: Logger.Options(level: .silent)))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Checksum before extraction

    /// Serves `payload` for every download and records whether extraction ran.
    private final class LocalDownloadCapgoUpdater: CapgoUpdater {
        var payload = Data()
        var downloadRequests = 0
        var extractionCalls = 0
        var sentStatsActions: [String] = []

        override func sendStats(action: String, versionName _: String? = nil, oldVersionName _: String? = "") {
            sentStatsActions.append(action)
        }

        override func performDownloadRequest(_ request: URLRequest, label _: String) -> DownloadRequestResult {
            downloadRequests += 1
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("capgo-hardening-\(UUID().uuidString).zip")
            do {
                try payload.write(to: fileURL)
            } catch {
                return DownloadRequestResult(fileURL: nil, response: nil, error: error, timedOut: false)
            }
            let response = HTTPURLResponse(url: request.url ?? fileURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
            return DownloadRequestResult(fileURL: fileURL, response: response, error: nil, timedOut: false)
        }

        override func saveDownloaded(sourceZip: URL, id: String, base: URL, notify: Bool, bufferSize: Int = CryptoCipher.ioBufferBytes()) throws {
            extractionCalls += 1
            try super.saveDownloaded(sourceZip: sourceZip, id: id, base: base, notify: notify, bufferSize: bufferSize)
        }
    }

    private func makeDownloadUpdater(payload: Data) -> LocalDownloadCapgoUpdater {
        let updater = LocalDownloadCapgoUpdater()
        updater.setLogger(Logger(withTag: "hardening-tests", options: Logger.Options(level: .silent)))
        // Payloads are served from file:// URLs.
        updater.httpsOnly = false
        updater.payload = payload
        return updater
    }

    private func bundleZipData() throws -> Data {
        var writer = TestZipWriter()
        writer.addFile("index.html", Data("<html>hardening</html>".utf8))
        return writer.build()
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func bundleDirectory(_ id: String) -> URL {
        libraryDir.appendingPathComponent("NoCloud/ionic_built_snapshots").appendingPathComponent(id)
    }

    func testDownloadRejectsChecksumMismatchBeforeExtraction() throws {
        let updater = makeDownloadUpdater(payload: try bundleZipData())
        defer { updater.shutdown() }
        // Never fetched: LocalDownloadCapgoUpdater serves the payload.
        let url = root.appendingPathComponent("update.zip")

        XCTAssertThrowsError(
            try updater.downloadVerified(url: url, version: "9.9.9-mismatch", sessionKey: "", expectedChecksum: String(repeating: "a", count: 64))
        ) { error in
            XCTAssertEqual(error as? ObjectSavableError, .checksum)
        }
        XCTAssertEqual(updater.downloadRequests, 1)
        XCTAssertEqual(updater.extractionCalls, 0, "an archive that fails verification must never be extracted")
        XCTAssertTrue(updater.sentStatsActions.contains("checksum_fail"))
        XCTAssertNil(updater.getBundleInfoByVersionName(version: "9.9.9-mismatch"), "the rejected bundle is dropped so it can be downloaded again")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: libraryDir.path).filter { $0.hasPrefix("capgo_unzip_") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testDownloadExtractsWhenChecksumMatches() throws {
        let zip = try bundleZipData()
        let updater = makeDownloadUpdater(payload: zip)
        defer { updater.shutdown() }
        // Never fetched: LocalDownloadCapgoUpdater serves the payload.
        let url = root.appendingPathComponent("update.zip")

        let bundle = try updater.downloadVerified(url: url, version: "9.9.9-match", sessionKey: "", expectedChecksum: sha256Hex(zip))
        defer { _ = updater.delete(id: bundle.getId()) }

        XCTAssertEqual(updater.extractionCalls, 1)
        XCTAssertEqual(bundle.getChecksum(), sha256Hex(zip))
        XCTAssertFalse(updater.sentStatsActions.contains("checksum_fail"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleDirectory(bundle.getId()).appendingPathComponent("index.html").path))
    }

    func testDownloadRequiresChecksumWhenExpectedChecksumIsEmpty() throws {
        // The shake menu passes the update response checksum; an empty one must stop before any download.
        let updater = makeDownloadUpdater(payload: try bundleZipData())
        defer { updater.shutdown() }
        // Never fetched: LocalDownloadCapgoUpdater serves the payload.
        let url = root.appendingPathComponent("update.zip")

        XCTAssertThrowsError(try updater.downloadVerified(url: url, version: "9.9.9-empty", sessionKey: "", expectedChecksum: ""))
        XCTAssertEqual(updater.downloadRequests, 0)
        XCTAssertEqual(updater.extractionCalls, 0)
        XCTAssertTrue(updater.sentStatsActions.contains("checksum_required"))
    }

    // MARK: - Zip symlinks

    private func makeUpdater() -> CapgoUpdater {
        let updater = CapgoUpdater()
        updater.setLogger(Logger(withTag: "hardening-tests", options: Logger.Options(level: .silent)))
        return updater
    }

    func testSaveDownloadedRejectsSymlinkChainEscape() throws {
        // m -> "." is harmless alone, but "l -> m/.." normalizes to the folder while physically pointing at its parent.
        let escapeName = "capgo-escape-\(UUID().uuidString)"
        var writer = TestZipWriter()
        writer.addFile("index.html", Data("<html></html>".utf8))
        writer.addSymlink("m", target: ".")
        writer.addSymlink("l", target: "m/..")
        writer.addFile("l/\(escapeName)", Data("owned".utf8))
        let zipURL = root.appendingPathComponent("chain.zip")
        try writer.write(to: zipURL)
        let base = root.appendingPathComponent("bundles")

        XCTAssertThrowsError(try makeUpdater().saveDownloaded(sourceZip: zipURL, id: "evil", base: base, notify: false))

        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryDir.appendingPathComponent(escapeName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("evil").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: libraryDir.path).filter { $0.hasPrefix("capgo_unzip_") }
        XCTAssertTrue(leftovers.isEmpty, "the temp unzip folder is removed on failure")
    }

    func testSaveDownloadedRejectsSymlinkTargetsWithParentSegmentsOrAbsolutePaths() throws {
        let targets = ["../index.html", "a/../b", "..", "/", "/tmp", "//etc"]
        for (index, target) in targets.enumerated() {
            var writer = TestZipWriter()
            writer.addFile("index.html", Data("<html></html>".utf8))
            writer.addSymlink("assets/link", target: target)
            let zipURL = root.appendingPathComponent("target-\(index).zip")
            try writer.write(to: zipURL)
            let base = root.appendingPathComponent("target-bundles-\(index)")
            XCTAssertThrowsError(
                try makeUpdater().saveDownloaded(sourceZip: zipURL, id: "evil", base: base, notify: false),
                "symlink target \(target) must be rejected"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("evil").path))
        }
    }

    func testSaveDownloadedKeepsSafeRelativeSymlinks() throws {
        var writer = TestZipWriter()
        writer.addFile("index.html", Data("<html></html>".utf8))
        writer.addSymlink("m", target: ".")
        writer.addFile("assets/app.js", Data("app".utf8))
        writer.addSymlink("alias", target: "assets/app.js")
        let zipURL = root.appendingPathComponent("safe.zip")
        try writer.write(to: zipURL)
        let base = root.appendingPathComponent("safe-bundles")

        try makeUpdater().saveDownloaded(sourceZip: zipURL, id: "ok", base: base, notify: false)

        let bundle = base.appendingPathComponent("ok")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: bundle.appendingPathComponent("alias").path), "assets/app.js")
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("alias")), Data("app".utf8))
    }

    func testPhysicalContainmentCheckFollowsSymlinks() throws {
        let inside = root.appendingPathComponent("inside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: inside.appendingPathComponent("up").path, withDestinationPath: "..")

        XCTAssertNoThrow(try CapgoUpdater.assertPhysicallyInsideDirectory(inside.appendingPathComponent("a/b"), root: inside))
        XCTAssertThrowsError(try CapgoUpdater.assertPhysicallyInsideDirectory(inside.appendingPathComponent("up/x"), root: inside))
        XCTAssertThrowsError(try CapgoUpdater.assertPhysicallyInsideDirectory(inside.appendingPathComponent("up"), root: inside))
    }

    // MARK: - AES strictness

    private let key = Data((0..<16).map { UInt8($0 * 7 & 0xff) })
    private let iv = Data((0..<16).map { UInt8($0 + 3) })

    private var aesKey: AES128Key {
        AES128Key(iv: iv, aes128Key: key, logger: Logger(withTag: "hardening-tests", options: Logger.Options(level: .silent)))
    }

    /// Reference AES-128-CBC decryption without any padding handling.
    private func rawCbcDecrypt(_ ciphertext: Data, iv chainingValue: Data) -> Data {
        let reference = AES128Key(iv: chainingValue, aes128Key: key, logger: Logger(withTag: "hardening-tests", options: Logger.Options(level: .silent)))
        guard let plain = reference.decryptBlocks(ciphertext) else {
            XCTFail("reference AES decryption failed")
            return Data()
        }
        return plain
    }

    /// Builds a `blocks`-long CBC ciphertext whose last block decrypts to `lastPlainBlock`, by choosing the
    /// previous ciphertext block (CBC: P[n] = D(C[n]) xor C[n-1]). No encryption is involved.
    private func makeCiphertext(blocks: Int, lastPlainBlock: [UInt8]) -> Data {
        precondition(blocks >= 2 && lastPlainBlock.count == kCCBlockSizeAES128)
        let blockSize = kCCBlockSizeAES128
        var bytes = (0..<(blocks * blockSize)).map { UInt8(($0 * 37 + 11) & 0xff) }
        let lastBlock = Data(bytes.suffix(blockSize))
        let decryptedLast = [UInt8](rawCbcDecrypt(lastBlock, iv: Data(count: blockSize)))
        for index in 0..<blockSize {
            bytes[(blocks - 2) * blockSize + index] = decryptedLast[index] ^ lastPlainBlock[index]
        }
        return Data(bytes)
    }

    private func block(filler: UInt8 = 0x41, tail: [UInt8]) -> [UInt8] {
        [UInt8](repeating: filler, count: kCCBlockSizeAES128 - tail.count) + tail
    }

    func testAesFileDecryptionRoundTripsAcrossChunks() throws {
        // Larger than two I/O buffers so the held-back padding block crosses chunk boundaries.
        let blocks = (CryptoCipher.ioBufferBytes() * 2) / kCCBlockSizeAES128 + 3
        let ciphertext = makeCiphertext(blocks: blocks, lastPlainBlock: block(tail: [UInt8](repeating: 5, count: 5)))
        let expected = rawCbcDecrypt(ciphertext, iv: iv).dropLast(5)
        let file = root.appendingPathComponent("round-trip.bin")
        try ciphertext.write(to: file)

        try aesKey.decrypt(from: file, to: file)

        XCTAssertEqual(try Data(contentsOf: file), Data(expected))
        let fullPadding = makeCiphertext(blocks: 2, lastPlainBlock: [UInt8](repeating: 16, count: 16))
        XCTAssertEqual(aesKey.decrypt(data: fullPadding), rawCbcDecrypt(fullPadding, iv: iv).prefix(16))
    }

    func testAesFileDecryptionRejectsCorruptedCiphertext() throws {
        let valid = makeCiphertext(blocks: 2, lastPlainBlock: block(tail: [3, 3, 3]))
        let cases: [(String, Data)] = [
            ("bad padding", makeCiphertext(blocks: 2, lastPlainBlock: block(tail: [1, 4, 4, 4]))),
            ("zero padding", makeCiphertext(blocks: 2, lastPlainBlock: block(tail: [0]))),
            ("padding > block", makeCiphertext(blocks: 2, lastPlainBlock: block(tail: [17]))),
            ("not block aligned", valid + Data([1, 2, 3])),
            ("truncated", valid.prefix(10))
        ]
        XCTAssertNotNil(aesKey.decrypt(data: valid), "the reference ciphertext is valid")
        for (name, ciphertext) in cases {
            let file = root.appendingPathComponent("corrupt-\(UUID().uuidString).bin")
            try ciphertext.write(to: file)
            XCTAssertThrowsError(try aesKey.decrypt(from: file, to: file), name)
            XCTAssertEqual(try Data(contentsOf: file), ciphertext, "\(name): the source is left untouched")
            XCTAssertNil(aesKey.decrypt(data: ciphertext), name)
        }
    }

    func testDecryptFileFailsWhenPublicKeyIsUnusable() throws {
        let file = root.appendingPathComponent("encrypted.bin")
        let ciphertext = makeCiphertext(blocks: 2, lastPlainBlock: block(tail: [1]))
        try ciphertext.write(to: file)

        XCTAssertThrowsError(
            try CryptoCipher.decryptFile(filePath: file, publicKey: "not-a-public-key", sessionKey: "aXY=:c2Vzc2lvbg==", version: "1.0.0")
        )
        XCTAssertEqual(try Data(contentsOf: file), ciphertext)
    }
}
