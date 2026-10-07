import XCTest
@testable import CapacitorUpdaterPlugin
import Capacitor

/// Inputs that used to crash the app: Objective-C exceptions Swift cannot catch,
/// numeric traps, and listener storage changed from two threads at once.
class CrashSafetyTests: XCTestCase {
    func testInvalidJSONIsRejectedInsteadOfRaising() throws {
        XCTAssertNil(CapgoCore.jsonString(["value": Double.nan]))
        XCTAssertNil(CapgoCore.jsonString(["value": Date()]))
        XCTAssertEqual(CapgoCore.jsonString(["a": 1]), "{\"a\":1}")
        XCTAssertThrowsError(try CapgoCore.call("resolvePathInside", ["root": Double.infinity]))
    }

    func testFarFutureStoredDateIsNotATrap() {
        XCTAssertNil(CapgoUpdater.storedString(Date(timeIntervalSince1970: 1e300)))
        XCTAssertEqual(CapgoUpdater.storedString(Date(timeIntervalSince1970: 1.5)), "1500")
    }

    func testPreviewSessionsWithNullStayAString() {
        let raw = "{\"abc\":{\"name\":null}}"
        let value = CapgoUpdater.legacyTypedValue("CapacitorUpdater.previewSessions", raw)
        XCTAssertEqual(value as? String, raw)
        let defaults = try? XCTUnwrap(UserDefaults(suiteName: "capgo-crash-safety-\(UUID().uuidString)"))
        defaults?.set(value, forKey: "CapacitorUpdater.previewSessions")
        XCTAssertEqual(defaults?.string(forKey: "CapacitorUpdater.previewSessions"), raw)
    }

    func testOnlyConfigErrorsStopTheAppAtLoad() {
        XCTAssertEqual(CapacitorUpdaterPlugin.fatalLoadErrors, ["missing_app_id", "invalid_public_key"])
    }

    /// The bridge calls addListener / removeAllListeners on its own queue while events are
    /// sent on main: this crashed (EXC_BAD_ACCESS in notifyListeners) within a second.
    func testListenerChangesWhileEventsAreSentDoNotCrash() {
        let plugin = CapacitorUpdaterPlugin()
        let bridgeQueue = DispatchQueue(label: "bridge-test")
        let stop = Date().addingTimeInterval(1.5)
        let done = expectation(description: "listener churn")
        bridgeQueue.async {
            var index = 0
            while Date() < stop {
                index += 1
                let call = CAPPluginCall(
                    callbackId: "listener-\(index)",
                    methodName: "addListener",
                    options: ["eventName": "download"],
                    success: { _, _ in },
                    error: { _ in }
                )!
                plugin.addListener(call)
                XCTAssertTrue(call.keepAlive)
                if index % 8 == 0 {
                    plugin.removeAllListeners(CAPPluginCall(
                        callbackId: "remove-\(index)",
                        methodName: "removeAllListeners",
                        options: [:],
                        success: { _, _ in },
                        error: { _ in }
                    )!)
                }
            }
            done.fulfill()
        }
        while Date() < stop {
            plugin.notifyListeners("download", data: ["percent": 1])
            RunLoop.current.run(until: Date().addingTimeInterval(0.0005))
        }
        wait(for: [done], timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
}
