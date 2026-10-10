import XCTest
@testable import CapacitorUpdaterPlugin

/// Signed bundle metadata (`signature` / `manifest_signature`), `builtinMinimum` and `httpsOnly` gates.
/// Signature vectors come from native-contract-tests/crypto-rsa.json (generated with Node privateEncrypt).
final class BundleSignatureTests: XCTestCase {
    private static let contract: [String: Any] = {
        guard let url = try? locateContractFile(),
              let data = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(with: data),
              let dict = value as? [String: Any] else {
            XCTFail("Unable to load RSA contract fixture")
            return [:]
        }
        return dict
    }()

    private static var publicKeyPem: String {
        contract["publicKeyPem"] as? String ?? ""
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
        throw NSError(domain: "BundleSignatureTests", code: 1)
    }

    private final class StatsTrackingCapgoUpdater: CapgoUpdater {
        var sentStatsActions: [String] = []

        override func sendStats(action: String, versionName: String? = nil, oldVersionName: String? = "") {
            sentStatsActions.append(action)
        }
    }

    override class func setUp() {
        super.setUp()
        CryptoCipher.setLogger(Logger(withTag: "BundleSignatureTests", options: Logger.Options(level: .silent)))
    }

    private func makeUpdater(publicKey: String = BundleSignatureTests.publicKeyPem) -> StatsTrackingCapgoUpdater {
        let updater = StatsTrackingCapgoUpdater()
        updater.setLogger(Logger(withTag: "BundleSignatureTests", options: Logger.Options(level: .silent)))
        updater.setPublicKey(publicKey)
        return updater
    }

    private func cases(_ key: String) throws -> [[String: Any]] {
        let value = try XCTUnwrap(Self.contract[key] as? [[String: Any]], "missing fixture section \(key)")
        XCTAssertFalse(value.isEmpty)
        return value
    }

    // MARK: - Fixture contract

    func testBundleSignatureMatchesNativeContract() throws {
        for testCase in try cases("bundleSignature") {
            let id = testCase["id"] as? String ?? "?"
            let input = try XCTUnwrap(testCase["input"] as? [String: Any], id)
            let expect = try XCTUnwrap(testCase["expect"] as? [String: Any], id)
            let version = try XCTUnwrap(input["version"] as? String, id)
            let checksumHex = try XCTUnwrap(input["checksumHex"] as? String, id)
            let encryptedChecksumHex = try XCTUnwrap(input["encryptedChecksumHex"] as? String, id)
            let signatureHex = try XCTUnwrap(input["signatureHex"] as? String, id)
            let expectedPayload = try XCTUnwrap(expect["payload"] as? String, id)
            let expectedValid = try XCTUnwrap(expect["valid"] as? Bool, id)

            let payload = CryptoCipher.buildBundleSignaturePayload(version: version, checksumHex: checksumHex)
            XCTAssertEqual(payload, expectedPayload, id)
            XCTAssertEqual(
                CryptoCipher.verifySignature(
                    signatureHex: signatureHex, payload: payload, publicKey: Self.publicKeyPem
                ),
                expectedValid,
                id
            )

            let updater = makeUpdater()
            if expectedValid {
                XCTAssertNoThrow(
                    try updater.verifyBundleSignature(
                        version: version, encryptedChecksum: encryptedChecksumHex, signature: signatureHex
                    ),
                    id
                )
                XCTAssertFalse(updater.sentStatsActions.contains("signature_fail"), id)
            } else {
                XCTAssertThrowsError(
                    try updater.verifyBundleSignature(
                        version: version, encryptedChecksum: encryptedChecksumHex, signature: signatureHex
                    ),
                    id
                ) { error in
                    XCTAssertEqual((error as NSError).localizedDescription, "Bundle signature verification failed", id)
                }
                XCTAssertTrue(updater.sentStatsActions.contains("signature_fail"), id)
            }
        }
    }

    func testManifestSignatureMatchesNativeContract() throws {
        for testCase in try cases("manifestSignature") {
            let id = testCase["id"] as? String ?? "?"
            let input = try XCTUnwrap(testCase["input"] as? [String: Any], id)
            let expect = try XCTUnwrap(testCase["expect"] as? [String: Any], id)
            let version = try XCTUnwrap(input["version"] as? String, id)
            let signatureHex = try XCTUnwrap(input["signatureHex"] as? String, id)
            let plainEntries = try XCTUnwrap(input["entries"] as? [[String: String]], id)
            let encryptedEntries = try XCTUnwrap(
                input["encryptedEntries"] as? [[String: String]], id
            )
            let expectedPayload = try XCTUnwrap(expect["payload"] as? String, id)
            let expectedValid = try XCTUnwrap(expect["valid"] as? Bool, id)

            let entries = try plainEntries.map { entry -> (fileName: String, hashHex: String) in
                (
                    fileName: try XCTUnwrap(entry["file_name"], id),
                    hashHex: try XCTUnwrap(entry["hashHex"], id)
                )
            }
            let payload = CryptoCipher.buildManifestSignaturePayload(version: version, entries: entries)
            XCTAssertEqual(payload, expectedPayload, id)
            XCTAssertEqual(
                CryptoCipher.verifySignature(
                    signatureHex: signatureHex, payload: payload, publicKey: Self.publicKeyPem
                ),
                expectedValid,
                id
            )

            let manifest = encryptedEntries.map {
                ManifestEntry(
                    file_name: $0["file_name"], file_hash: $0["file_hash"], download_url: "https://example.com/f"
                )
            }
            let updater = makeUpdater()
            if expectedValid {
                XCTAssertNoThrow(
                    try updater.verifyManifestSignature(
                        version: version, manifest: manifest, signature: signatureHex
                    ),
                    id
                )
            } else {
                XCTAssertThrowsError(
                    try updater.verifyManifestSignature(
                        version: version, manifest: manifest, signature: signatureHex
                    ),
                    id
                )
                XCTAssertTrue(updater.sentStatsActions.contains("signature_fail"), id)
            }
        }
    }

    // MARK: - Gate semantics

    func testMissingSignatureIsAcceptedForLegacyBundles() throws {
        let updater = makeUpdater()
        let manifest = [
            ManifestEntry(file_name: "index.html", file_hash: "00", download_url: "https://example.com/f")
        ]
        XCTAssertNoThrow(try updater.verifyBundleSignature(version: "1.0.0", encryptedChecksum: "00", signature: ""))
        XCTAssertNoThrow(try updater.verifyManifestSignature(version: "1.0.0", manifest: manifest, signature: ""))
        XCTAssertTrue(updater.sentStatsActions.isEmpty)
    }

    func testSignatureIsIgnoredWithoutPublicKey() throws {
        let updater = makeUpdater(publicKey: "")
        XCTAssertNoThrow(try updater.verifyBundleSignature(version: "1.0.0", encryptedChecksum: "abc", signature: "zz"))
    }

    func testBuiltinMinimumRejectsVersionBelowNative() throws {
        let updater = makeUpdater(publicKey: "")
        updater.versionBuild = "2.0.0"
        XCTAssertThrowsError(try updater.requireVersionNotBelowBuiltin("1.9.9")) { error in
            XCTAssertEqual((error as NSError).code, 8)
            XCTAssertEqual(
                (error as NSError).localizedDescription,
                "Bundle version 1.9.9 is below native version 2.0.0 (builtinMinimum)"
            )
        }
        XCTAssertEqual(updater.sentStatsActions, ["version_below_native"])
        XCTAssertNoThrow(try updater.requireVersionNotBelowBuiltin("2.0.0"))
        XCTAssertNoThrow(try updater.requireVersionNotBelowBuiltin("2.0.1"))
        // Unparseable versions never block.
        XCTAssertNoThrow(try updater.requireVersionNotBelowBuiltin("builtin"))
        updater.versionBuild = "not-a-version"
        XCTAssertNoThrow(try updater.requireVersionNotBelowBuiltin("0.0.1"))
    }

    func testBuiltinMinimumCanBeDisabled() throws {
        let updater = makeUpdater(publicKey: "")
        updater.versionBuild = "2.0.0"
        updater.builtinMinimum = false
        XCTAssertNoThrow(try updater.requireVersionNotBelowBuiltin("1.0.0"))
        XCTAssertTrue(updater.sentStatsActions.isEmpty)
    }

    func testBuiltinMinimumGatesDownloadBeforeNetwork() throws {
        let updater = makeUpdater(publicKey: "")
        updater.versionBuild = "3.0.0"
        let url = try XCTUnwrap(URL(string: "https://example.com/update.zip"))
        XCTAssertThrowsError(
            try updater.downloadVerified(url: url, version: "2.0.0", sessionKey: "", expectedChecksum: "abc")
        ) { error in
            XCTAssertEqual((error as NSError).code, 8)
        }
        let manifest = [
            ManifestEntry(file_name: "index.html", file_hash: "00", download_url: "https://example.com/f")
        ]
        XCTAssertThrowsError(
            try updater.downloadManifest(manifest: manifest, version: "2.0.0", sessionKey: "")
        ) { error in
            XCTAssertEqual((error as NSError).code, 8)
        }
    }

    func testHttpsOnlyRejectsPlainHttpBeforeNetwork() throws {
        let updater = makeUpdater(publicKey: "")
        let httpUrl = try XCTUnwrap(URL(string: "http://example.com/update.zip"))
        XCTAssertThrowsError(
            try updater.downloadVerified(url: httpUrl, version: "1.0.0", sessionKey: "", expectedChecksum: "abc")
        ) { error in
            XCTAssertEqual(
                (error as NSError).localizedDescription,
                "httpsOnly is enabled and http://example.com/update.zip is not https"
            )
        }
        let manifest = [
            ManifestEntry(file_name: "index.html", file_hash: "00", download_url: "http://example.com/f")
        ]
        XCTAssertThrowsError(
            try updater.downloadManifest(manifest: manifest, version: "1.0.0", sessionKey: "")
        ) { error in
            XCTAssertEqual((error as NSError).code, 7)
        }

        let done = expectation(description: "raw task rejected")
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:1/updates")))
        request.timeoutInterval = 1
        updater.startRawDataTask(request) { data, _, error in
            XCTAssertNil(data)
            XCTAssertEqual((error as NSError?)?.code, 7)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        updater.httpsOnly = false
        XCTAssertNil(updater.checkAllowedScheme(httpUrl))
    }

    func testHttpsOnlyBlocksRedirectToHttpEvenWhenDowngradeAllowed() throws {
        let delegate = RedirectPolicyDelegate()
        delegate.allowHttpsToHttpRedirect = true
        delegate.httpsOnly = true
        var blocked = false
        delegate.onBlockedRedirect = { _, _ in blocked = true }
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: try XCTUnwrap(URL(string: "https://example.com/a")))
        let sourceUrl = try XCTUnwrap(URL(string: "https://example.com/a"))
        let response = try XCTUnwrap(
            HTTPURLResponse(url: sourceUrl, statusCode: 302, httpVersion: nil, headerFields: nil)
        )
        let httpRequest = URLRequest(url: try XCTUnwrap(URL(string: "http://example.com/b")))
        let placeholder = try XCTUnwrap(URL(string: "https://placeholder"))
        var forwarded: URLRequest? = URLRequest(url: placeholder)
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: httpRequest) {
            forwarded = $0
        }
        XCTAssertNil(forwarded)
        XCTAssertTrue(blocked)

        delegate.httpsOnly = false
        blocked = false
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: httpRequest) {
            forwarded = $0
        }
        XCTAssertNotNil(forwarded)
        XCTAssertFalse(blocked)
    }
}
