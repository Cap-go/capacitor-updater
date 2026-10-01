import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

/// The engine's `proxyForUrl` hook: the system proxy settings URLSession used (Wi-Fi / MDM).
final class SystemProxyTests: XCTestCase {
    private func entry(_ type: CFString, host: String? = nil, port: Int? = nil) -> [String: Any] {
        var entry: [String: Any] = [kCFProxyTypeKey as String: type as String]
        entry[kCFProxyHostNameKey as String] = host
        entry[kCFProxyPortNumberKey as String] = port.map { NSNumber(value: $0) }
        return entry
    }

    func testHttpAndHttpsProxiesAreReportedWithHostAndPort() {
        let http = CapgoUpdater.proxyReply([entry(kCFProxyTypeHTTP, host: "proxy.corp", port: 3128)])
        XCTAssertEqual(http["type"] as? String, "http")
        XCTAssertEqual(http["host"] as? String, "proxy.corp")
        XCTAssertEqual(http["port"] as? Int, 3128)
        let https = CapgoUpdater.proxyReply([entry(kCFProxyTypeHTTPS, host: "secure.corp", port: 8443)])
        XCTAssertEqual(https["type"] as? String, "http")
        XCTAssertEqual(https["host"] as? String, "secure.corp")
    }

    func testDirectUnsupportedAndPacConfigurationsConnectDirectly() {
        XCTAssertEqual(CapgoUpdater.proxyReply([])["type"] as? String, "direct")
        XCTAssertEqual(CapgoUpdater.proxyReply([entry(kCFProxyTypeNone)])["type"] as? String, "direct")
        XCTAssertEqual(
            CapgoUpdater.proxyReply([entry(kCFProxyTypeNone), entry(kCFProxyTypeHTTP, host: "proxy.corp", port: 3128)])["type"] as? String,
            "direct"
        )
        XCTAssertEqual(CapgoUpdater.proxyReply([entry(kCFProxyTypeHTTP, host: "", port: 3128)])["type"] as? String, "direct")
        XCTAssertEqual(CapgoUpdater.proxyReply([entry(kCFProxyTypeHTTP, host: "proxy.corp", port: 0)])["type"] as? String, "direct")
        // SOCKS is skipped for the next usable HTTP proxy.
        let afterSocks = CapgoUpdater.proxyReply([
            entry(kCFProxyTypeSOCKS, host: "socks.corp", port: 1080),
            entry(kCFProxyTypeHTTP, host: "proxy.corp", port: 8080)
        ])
        XCTAssertEqual(afterSocks["host"] as? String, "proxy.corp")

        var logs: [String] = []
        let pac = CapgoUpdater.proxyReply([entry(kCFProxyTypeAutoConfigurationURL)]) { logs.append($0) }
        XCTAssertEqual(pac["type"] as? String, "direct")
        XCTAssertEqual(logs.count, 1)
    }

    func testSettingsAreResolvedPerUrlByCFNetwork() {
        let settings = [
            "HTTPEnable": 1,
            "HTTPProxy": "proxy.corp",
            "HTTPPort": 3128,
            "ExceptionsList": ["*.local"]
        ] as CFDictionary
        let proxied = CapgoUpdater.systemProxy(for: "http://plugin.capgo.app/updates", settings: settings)
        XCTAssertEqual(proxied["type"] as? String, "http")
        XCTAssertEqual(proxied["host"] as? String, "proxy.corp")
        XCTAssertEqual(proxied["port"] as? Int, 3128)
        XCTAssertEqual(CapgoUpdater.systemProxy(for: "http://printer.local/", settings: settings)["type"] as? String, "direct")
        XCTAssertEqual(CapgoUpdater.systemProxy(for: "https://plugin.capgo.app/", settings: nil)["type"] as? String, "direct")
        XCTAssertEqual(CapgoUpdater.systemProxy(for: "", settings: settings)["type"] as? String, "direct")
    }
}
