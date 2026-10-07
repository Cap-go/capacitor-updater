import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

/// Smoke test of the C ABI binding: one core call and one engine call. The
/// shared contract fixtures (native-contract-tests/) run in Rust (core/tests/contract.rs).
final class CoreBindingTests: XCTestCase {
    func testCoreCallReturnsValuesAndErrorCodes() throws {
        let resolved = try CapgoCore.call("resolvePathInside", ["base": "/data/versions", "path": "abc"])
        XCTAssertEqual(resolved["path"] as? String, "/data/versions/abc")
        XCTAssertThrowsError(try CapgoCore.call("resolvePathInside", ["base": "/data/versions", "path": "../abc"])) { error in
            XCTAssertEqual((error as? CapgoCore.Failure)?.code, "path_traversal")
        }
    }

    func testEngineCallReachesTheHost() throws {
        let updater = StatsRecordingCapgoUpdater()
        defer {
            updater.shutdown()
        }
        let id = "binding-\(UUID().uuidString.prefix(8))"
        let saved = try updater.engineCall("bundleSave", [
            "id": id,
            "bundle": ["id": id, "version": "1.2.3", "status": "success"]
        ])
        XCTAssertEqual(saved["saved"] as? Bool, true)
        XCTAssertEqual(try updater.engineCall("bundleGet", ["id": id])["version"] as? String, "1.2.3")
        _ = try updater.engineCall("bundleDelete", ["id": id, "removeInfo": true])
    }
}
