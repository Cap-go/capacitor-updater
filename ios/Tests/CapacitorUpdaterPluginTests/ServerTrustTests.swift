import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

/// TLS trust for the engine's HTTP client is the `verify_server_certificate` host callback
/// (SecTrust). The engine also checks the host name and fails closed without an answer
/// (core/tests/net_tls.rs); these tests pin the Swift side with fixed chains and dates.
final class ServerTrustTests: XCTestCase {
    /// www.apple.com leaf (valid 2026-07-02 to 2026-12-16) and its intermediate
    /// (Apple Public EV Server RSA CA 1 - G1, under DigiCert Global Root G2).
    private static let appleChain: [Data] = [
        [
            "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",
        ].joined(),
        [
            "MIIFHjCCBAagAwIBAgIQBPIuzCH8tDgqwouPLWQfwDANBgkqhkiG9w0BAQsFADBhMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGln",
            "aUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSAwHgYDVQQDExdEaWdpQ2VydCBHbG9iYWwgUm9vdCBHMjAeFw0y",
            "MDA0MjkxMjU1MzRaFw0zMDA0MTAyMzU5NTlaMFExCzAJBgNVBAYTAlVTMRMwEQYDVQQKEwpBcHBsZSBJbmMuMS0wKwYDVQQDEyRB",
            "cHBsZSBQdWJsaWMgRVYgU2VydmVyIFJTQSBDQSAxIC0gRzEwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDfn5fdV0A4",
            "cCNFu0EvUgduZVPyPZity4q8Re1TcE9qGyWoVpzHm9OluDlqwcvudbLwBe25PWA2Z9xFpVKK9jGW6Vt79N7if7dfi9w2+2zG+/wJ",
            "u1Z6TA8RENTVuJTaMwqQXw1dTkZEOgjCEKa75uyzXl+mIa0s4GdxkCBclGI9WDsUFlLj3A6eBIzeTomTl7LhIV+nQUEWTqkwG5Pc",
            "xckiv7Xn1mu7EVWUukZWY8uL+KhcTJQZYtxNj3PeM73WZ3fraixPA+RBkVnG5NgObRnrk5VHwjntbit9892kp7EISZK4Izfm99Qg",
            "P4V2IqHFsKxfCnZqfwUHikxftIVkjXIdAgMBAAGjggHgMIIB3DAdBgNVHQ4EFgQU073BPKDPNbk0xdTb2hAOTN5q/lgwHwYDVR0j",
            "BBgwFoAUTiJUIBiV5uNu5g/6+rkS7QYXjzkwDgYDVR0PAQH/BAQDAgGGMB0GA1UdJQQWMBQGCCsGAQUFBwMBBggrBgEFBQcDAjAS",
            "BgNVHRMBAf8ECDAGAQH/AgEAMDQGCCsGAQUFBwEBBCgwJjAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEIG",
            "A1UdHwQ7MDkwN6A1oDOGMWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEdsb2JhbFJvb3RHMi5jcmwwgdwGA1UdIASB",
            "1DCB0TCBxQYJYIZIAYb9bAIBMIG3MCgGCCsGAQUFBwIBFhxodHRwczovL3d3dy5kaWdpY2VydC5jb20vQ1BTMIGKBggrBgEFBQcC",
            "AjB+DHxBbnkgdXNlIG9mIHRoaXMgQ2VydGlmaWNhdGUgY29uc3RpdHV0ZXMgYWNjZXB0YW5jZSBvZiB0aGUgUmVseWluZyBQYXJ0",
            "eSBBZ3JlZW1lbnQgbG9jYXRlZCBhdCBodHRwczovL3d3dy5kaWdpY2VydC5jb20vcnBhLXVhMAcGBWeBDAEBMA0GCSqGSIb3DQEB",
            "CwUAA4IBAQBD9c6SmtMxGjRwc/A1bPiM+r1qj5xbDzGn6s6m6oggm9UeBLCSUNJthKffNPqqwtULeeUddssewaOZX+uHjG9bY/O9",
            "J1VQtGtXI2hndyAPiloqNjf5iBW16h3ZIUFQL319hISioItFVJZnVe4gjNEWio1ZRwO5A4e/H69/lPAX294yGtYGllAdv2NexhUM",
            "fjODhCajoTJmkXbyIpYzTNkgDXvQptTecrvr0rPzEMWfTtGSppbOC+s/5jG3aJ6GJn49Ram1ZLEGHTx9PWUoHth9Lj7vwFBD9667",
            "x9m9nUhuET9a3XvNep+N7w96ZqH2fAqUBW1kl6u3u67D6mvDsCQr",
        ].joined()
    ].map { Data(base64Encoded: $0)! }

    /// Self-signed EC certificate for `localhost` (not in any trust store).
    private static let selfSigned = Data(base64Encoded: [
        "MIIBlTCCATugAwIBAgIUJ5aRle5e8iK9YLs/MZNuxZYugd0wCgYIKoZIzj0EAwIwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2",
        "MTAwMTAzMTY1MVoYDzIxMjYwOTA3MDMxNjUxWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNC",
        "AAQPuthMBpvhPqOhuFEwC3eYmswof9VhLzrSNCLx7zY3Rc2nS3tQvldeDafMd3KqdSwm5Em0rWqI57+KpSTHmUf+o2kwZzAdBgNV",
        "HQ4EFgQUYt8DOmvp6RcdA1LBK7EHHfW5gGgwHwYDVR0jBBgwFoAUYt8DOmvp6RcdA1LBK7EHHfW5gGgwDwYDVR0TAQH/BAUwAwEB",
        "/zAUBgNVHREEDTALgglsb2NhbGhvc3QwCgYIKoZIzj0EAwIDSAAwRQIhAI5s0aFIxwPQtpTmjpdv2WZ0cAeCznQ5KTwV1L+Jj5k8",
        "AiA9dehLNJAhExhzonmiMWF0qIR1juFPqLYcjoXW4Ty+Ng==",
    ].joined())!

    private static let insideValidity = Date(timeIntervalSince1970: 1_788_220_800) // 2026-09-01
    private static let afterExpiry = Date(timeIntervalSince1970: 1_893_456_000) // 2030-01-01

    func testSystemTrustStoreAcceptsAValidChainForItsName() {
        XCTAssertNil(CapgoEngine.verifyServerCertificate(
            chain: Self.appleChain, serverName: "www.apple.com", date: Self.insideValidity
        ))
    }

    // SPKI SHA-256 (base64) computed with openssl from the chain above.
    private static let appleLeafPin = "Y4IXG8Fr0usWRIkGqnw30wN1W7aRBNVbnhizvQ2tlXI="
    private static let appleIntermediatePin = "9C7mf4J789KvLX59lcMyYpsH6bpdmoAGTByZNhcusLA="

    func testSpkiHashMatchesOpenssl() {
        XCTAssertEqual(CapgoEngine.spkiSha256Base64(certificate: Self.appleChain[0]), Self.appleLeafPin)
        XCTAssertEqual(CapgoEngine.spkiSha256Base64(certificate: Self.appleChain[1]), Self.appleIntermediatePin)
        XCTAssertNil(CapgoEngine.spkiSha256Base64(certificate: Data([0x30, 0x03, 0x02, 0x01])))
    }

    /// NSPinnedDomains, as URLSession applies it.
    func testPinnedDomainsAreEnforced() {
        func verify(_ pinned: [String: Any], host: String = "www.apple.com") -> String? {
            CapgoEngine.verifyServerCertificate(
                chain: Self.appleChain, serverName: host, date: Self.insideValidity, pinnedDomains: pinned
            )
        }
        let leaf: [String: Any] = ["www.apple.com": ["NSPinnedLeafIdentities": [["SPKI-SHA256-BASE64": Self.appleLeafPin]]]]
        XCTAssertNil(verify(leaf))
        let wrongLeaf: [String: Any] = ["www.apple.com": ["NSPinnedLeafIdentities": [["SPKI-SHA256-BASE64": Self.appleIntermediatePin]]]]
        XCTAssertNotNil(verify(wrongLeaf))
        let ca: [String: Any] = ["apple.com": ["NSIncludesSubdomains": true, "NSPinnedCAIdentities": [["SPKI-SHA256-BASE64": Self.appleIntermediatePin]]]]
        XCTAssertNil(verify(ca))
        let wrongCa: [String: Any] = ["apple.com": ["NSIncludesSubdomains": true, "NSPinnedCAIdentities": [["SPKI-SHA256-BASE64": Self.appleLeafPin]]]]
        XCTAssertNotNil(verify(wrongCa))
        // Without NSIncludesSubdomains the parent domain does not pin www.apple.com.
        let parentOnly: [String: Any] = ["apple.com": ["NSPinnedLeafIdentities": [["SPKI-SHA256-BASE64": "AAAA"]]]]
        XCTAssertNil(verify(parentOnly))
        // Both lists present: both must match.
        let both: [String: Any] = ["www.apple.com": [
            "NSPinnedLeafIdentities": [["SPKI-SHA256-BASE64": Self.appleLeafPin]],
            "NSPinnedCAIdentities": [["SPKI-SHA256-BASE64": "AAAA"]]
        ]]
        XCTAssertNotNil(verify(both))
        // The most specific domain applies.
        let nested: [String: Any] = [
            "apple.com": ["NSIncludesSubdomains": true, "NSPinnedLeafIdentities": [["SPKI-SHA256-BASE64": "AAAA"]]],
            "www.apple.com": ["NSPinnedLeafIdentities": [["SPKI-SHA256-BASE64": Self.appleLeafPin]]]
        ]
        XCTAssertNil(verify(nested))
        // A malformed pin list fails closed instead of disabling the pin check.
        XCTAssertNotNil(verify(["www.apple.com": ["NSPinnedLeafIdentities": Self.appleLeafPin]]))
        let malformedCa = ["SPKI-SHA256-BASE64": Self.appleIntermediatePin]
        XCTAssertNotNil(verify(["www.apple.com": ["NSPinnedCAIdentities": malformedCa]]))
        // Pinning never makes an untrusted chain acceptable.
        XCTAssertNotNil(CapgoEngine.verifyServerCertificate(
            chain: Self.appleChain, serverName: "www.apple.com", date: Self.afterExpiry, pinnedDomains: leaf
        ))
    }

    func testRejectsAnotherNameAnExpiredLeafAndAnIncompleteChain() {
        XCTAssertNotNil(CapgoEngine.verifyServerCertificate(
            chain: Self.appleChain, serverName: "capgo.app", date: Self.insideValidity
        ))
        XCTAssertNotNil(CapgoEngine.verifyServerCertificate(
            chain: Self.appleChain, serverName: "www.apple.com", date: Self.afterExpiry
        ))
        XCTAssertNotNil(CapgoEngine.verifyServerCertificate(
            chain: Array(Self.appleChain.dropFirst()), serverName: "www.apple.com", date: Self.insideValidity
        ))
    }

    func testRejectsSelfSignedGarbageAndEmptyChains() {
        XCTAssertNotNil(CapgoEngine.verifyServerCertificate(chain: [Self.selfSigned], serverName: "localhost"))
        XCTAssertNotNil(CapgoEngine.verifyServerCertificate(chain: [Data([0x30, 0x03, 0x02, 0x01, 0x00])], serverName: "localhost"))
        XCTAssertNotNil(CapgoEngine.verifyServerCertificate(chain: [], serverName: "localhost"))
    }

    /// The C callback the engine calls: only 1 trusts, a rejection carries a reason.
    func testCallbackRejectsWithAReasonAndFailsClosedOnBadInput() {
        func call(_ chain: [Data], _ serverName: String?) -> (Int32, String?) {
            let buffers = chain.map { data -> UnsafeMutablePointer<UInt8> in
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(data.count, 1))
                data.copyBytes(to: buffer, count: data.count)
                return buffer
            }
            defer { buffers.forEach { $0.deallocate() } }
            let pointers: [UnsafePointer<UInt8>?] = buffers.map { UnsafePointer($0) }
            let lengths = chain.map(\.count)
            var error: UnsafeMutablePointer<CChar>?
            let verdict = pointers.withUnsafeBufferPointer { certificates in
                lengths.withUnsafeBufferPointer { lengths in
                    withUnsafeMutablePointer(to: &error) { error in
                        if let serverName {
                            return serverName.withCString { name in
                                CapgoEngine.verifyServerCertificateCallback(
                                    nil, name, certificates.baseAddress, lengths.baseAddress, chain.count, error
                                )
                            }
                        }
                        return CapgoEngine.verifyServerCertificateCallback(
                            nil, nil, certificates.baseAddress, lengths.baseAddress, chain.count, error
                        )
                    }
                }
            }
            defer { free(error) }
            return (verdict, error.map { String(cString: $0) })
        }

        let selfSigned = call([Self.selfSigned], "localhost")
        XCTAssertEqual(selfSigned.0, 0)
        XCTAssertFalse(selfSigned.1?.isEmpty ?? true)
        XCTAssertEqual(call([Self.appleChain[0]], "capgo.app").0, 0)
        XCTAssertEqual(call([], "localhost").0, 0)
        XCTAssertEqual(call([Self.selfSigned], nil).0, 0)
        XCTAssertEqual(call([Data([1, 2, 3])], "localhost").0, 0)
    }
}

/// End to end: a real HTTPS request from the engine, verified by the Swift trust callback.
final class EngineHttpsTests: XCTestCase {
    func testEngineReachesARealHttpsServerThroughTheTrustCallback() throws {
        let probe = expectation(description: "network probe")
        var online = false
        URLSession.shared.dataTask(with: URL(string: "https://plugin.capgo.app/ok")!) { _, response, _ in
            online = response != nil
            probe.fulfill()
        }.resume()
        wait(for: [probe], timeout: 20)
        try XCTSkipUnless(online, "No network: cannot reach plugin.capgo.app")

        let updater = StatsRecordingCapgoUpdater()
        defer {
            updater.shutdown()
        }
        let reply = try updater.engineCall("getLatest", ["updateUrl": "https://plugin.capgo.app/updates"])
        // Any server answer proves TLS worked; a TLS or transport failure is a network_error.
        XCTAssertNotEqual(reply["error"] as? String, "network_error", "\(reply)")
        XCTAssertNotNil(reply["statusCode"] ?? reply["version"] ?? reply["error"], "\(reply)")
    }
}
