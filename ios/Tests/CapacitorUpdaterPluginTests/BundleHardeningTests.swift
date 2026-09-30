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
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
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
        let url = URL(string: "https://example.com/update.zip")!

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
        let url = URL(string: "https://example.com/update.zip")!

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
        let url = URL(string: "https://example.com/update.zip")!

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

    /// Encrypts like the Capgo CLI (AES-128-CBC with PKCS#7) through the streaming CommonCrypto API.
    private func aesEncrypt(_ plain: Data) -> Data {
        var cryptor: CCCryptorRef?
        let keyBytes = [UInt8](key)
        let ivBytes = [UInt8](iv)
        let createStatus = CCCryptorCreate(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            keyBytes,
            keyBytes.count,
            ivBytes,
            &cryptor
        )
        guard createStatus == kCCSuccess, let cryptor else {
            XCTFail("cannot create AES encryptor")
            return Data()
        }
        defer { CCCryptorRelease(cryptor) }
        let input = [UInt8](plain)
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var updateMoved = 0
        XCTAssertEqual(CCCryptorUpdate(cryptor, input, input.count, &out, out.count, &updateMoved), CCCryptorStatus(kCCSuccess))
        var finalMoved = 0
        let finalStatus = out.withUnsafeMutableBufferPointer { buffer in
            CCCryptorFinal(cryptor, buffer.baseAddress?.advanced(by: updateMoved), buffer.count - updateMoved, &finalMoved)
        }
        XCTAssertEqual(finalStatus, CCCryptorStatus(kCCSuccess))
        return Data(out.prefix(updateMoved + finalMoved))
    }

    /// CBC encryption of a single 16-byte block with no padding: it is the first block of its padded encryption.
    private func aesEncryptRawBlock(_ block: [UInt8]) -> Data {
        XCTAssertEqual(block.count, kCCBlockSizeAES128)
        return aesEncrypt(Data(block)).prefix(kCCBlockSizeAES128)
    }

    private var aesKey: AES128Key {
        AES128Key(iv: iv, aes128Key: key, logger: Logger(withTag: "hardening-tests", options: Logger.Options(level: .silent)))
    }

    private func badPaddingCiphertext() -> Data {
        // Claims 4 bytes of padding but the padding bytes differ.
        var block = [UInt8](repeating: 0x41, count: 16)
        block[12] = 1
        block[13] = 4
        block[14] = 4
        block[15] = 4
        return aesEncryptRawBlock(block)
    }

    func testAesFileDecryptionRoundTripsAcrossChunks() throws {
        let plain = Data((0..<(CryptoCipher.ioBufferBytes() * 2 + 5)).map { UInt8($0 * 31 & 0xff) })
        let file = root.appendingPathComponent("round-trip.bin")
        try aesEncrypt(plain).write(to: file)

        try aesKey.decrypt(from: file, to: file)

        XCTAssertEqual(try Data(contentsOf: file), plain)
        XCTAssertEqual(aesKey.decrypt(data: aesEncrypt(Data("short".utf8))), Data("short".utf8))
    }

    func testAesFileDecryptionRejectsCorruptedCiphertext() throws {
        let valid = aesEncrypt(Data("capgo-strict-aes".utf8))
        var zeroPadding = [UInt8](repeating: 0x41, count: 16)
        zeroPadding[15] = 0
        var oversizedPadding = [UInt8](repeating: 0x41, count: 16)
        oversizedPadding[15] = 17
        let cases: [(String, Data)] = [
            ("bad padding", badPaddingCiphertext()),
            ("zero padding", aesEncryptRawBlock(zeroPadding)),
            ("padding > block", aesEncryptRawBlock(oversizedPadding)),
            ("not block aligned", valid + Data([1, 2, 3])),
            ("truncated", valid.prefix(10))
        ]
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
        let ciphertext = aesEncrypt(Data("encrypted bundle".utf8))
        try ciphertext.write(to: file)

        XCTAssertThrowsError(
            try CryptoCipher.decryptFile(filePath: file, publicKey: "not-a-public-key", sessionKey: "aXY=:c2Vzc2lvbg==", version: "1.0.0")
        )
        XCTAssertEqual(try Data(contentsOf: file), ciphertext)
    }
}
