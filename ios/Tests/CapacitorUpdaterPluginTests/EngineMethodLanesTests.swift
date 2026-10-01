import XCTest
@testable import CapacitorUpdaterPlugin

/// JavaScript methods run in call order on the method lane; network and reloading
/// methods are detached from it so they never block the calls that follow.
class EngineMethodLanesTests: XCTestCase {
    private var plugin: CapacitorUpdaterPlugin!
    private var implementation: CapgoUpdater!
    private var noBackupDir: URL!

    override func setUp() {
        super.setUp()
        plugin = CapacitorUpdaterPlugin()
        implementation = CapgoUpdater()
        implementation.setLogger(Logger(withTag: "EngineMethodLanesTests", options: Logger.Options(level: .silent)))
        implementation.appId = "com.capgo.ios.tests"
        implementation.deviceID = "ios-tests-device"
        implementation.versionBuild = "1.0.0"
        noBackupDir = FileManager.default.temporaryDirectory.appendingPathComponent("capgo-lanes-\(UUID().uuidString)")
    }

    override func tearDown() {
        implementation?.shutdown()
        plugin = nil
        implementation = nil
        if let noBackupDir {
            try? FileManager.default.removeItem(at: noBackupDir)
        }
        super.tearDown()
    }

    /// Loads the plugin layer with every endpoint disabled (no network in tests).
    private func loadEngine(config extra: [String: Any] = [:], native extraNative: [String: Any] = [:]) throws {
        var config: [String: Any] = ["autoUpdate": false, "updateUrl": "", "statsUrl": "", "channelUrl": ""]
        config.merge(extra) { $1 }
        var native: [String: Any] = [
            "versionName": "1.0.0",
            "versionCode": "1",
            "noBackupDir": noBackupDir.path,
            "trackUncleanExits": false
        ]
        native.merge(extraNative) { $1 }
        let engine = try XCTUnwrap(implementation.engine())
        _ = try engine.call("pluginLoad", ["config": config, "native": native])
    }

    /// Lanes over this test's engine, with the detached methods the engine reports.
    private func methodLanes() throws -> EngineMethodLanes {
        plugin.implementation = implementation
        let names = try XCTUnwrap(implementation.engine()?.callValue("detachedPluginMethods") as? [String])
        plugin.methodLanes.setDetachedMethods(names)
        return plugin.methodLanes
    }

    private static func resolvedObject(_ outcome: CapacitorUpdaterPlugin.MethodOutcome) -> [String: Any]? {
        if case .resolved(let value) = outcome {
            return value as? [String: Any]
        }
        return nil
    }

    /// Calls JavaScript does not await run in call order, like the bridge queue ran them.
    func testQuickMethodsRunInCallOrder() throws {
        try loadEngine()
        _ = try methodLanes()
        let rounds = 200
        var seen = [Bool?](repeating: nil, count: rounds)
        let lock = NSLock()
        let done = expectation(description: "every read")
        done.expectedFulfillmentCount = rounds
        for round in 0..<rounds {
            plugin.dispatchEngineMethod("setShakeMenu", ["enabled": round % 2 == 0]) { _ in }
            plugin.dispatchEngineMethod("isShakeMenuEnabled", [:]) { outcome in
                lock.lock()
                seen[round] = Self.resolvedObject(outcome)?["enabled"] as? Bool
                lock.unlock()
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)
        lock.lock()
        defer { lock.unlock() }
        for round in 0..<rounds {
            XCTAssertEqual(seen[round], round % 2 == 0, "round \(round)")
        }
    }

    /// A reload that waits for notifyAppReady runs off the lane: notifyAppReady is not stuck behind it.
    func testReloadingMethodsDoNotBlockNotifyAppReady() throws {
        var finished: [String] = []
        var resetResolved = false
        var reloading = false
        let lock = NSLock()
        let done = expectation(description: "reset, notifyAppReady and current")
        done.expectedFulfillmentCount = 3
        let plugin = self.plugin!
        implementation.onHook = { name, _ in
            guard name == "applyBundle" else {
                return nil
            }
            lock.lock()
            let confirm = reloading
            reloading = false
            lock.unlock()
            if confirm {
                // The reloaded page confirms itself through the lane while reset waits for it.
                plugin.dispatchEngineMethod("notifyAppReady", [:]) { _ in
                    lock.lock()
                    finished.append("notifyAppReady")
                    lock.unlock()
                    done.fulfill()
                }
            }
            return ["ok": true, "guard": false]
        }
        try loadEngine(config: ["appReadyTimeout": 8000], native: ["reloadWaitsForAppReady": true])
        let lanes = try methodLanes()
        XCTAssertTrue(lanes.isDetached("reset"))
        XCTAssertTrue(lanes.isDetached("set"))
        XCTAssertTrue(lanes.isDetached("reload"))
        XCTAssertFalse(lanes.isDetached("notifyAppReady"))
        _ = try implementation.engineCall("pluginMethod", ["name": "notifyAppReady", "args": [:]])

        lock.lock()
        reloading = true
        lock.unlock()
        let started = Date()
        plugin.dispatchEngineMethod("reset", [:]) { outcome in
            lock.lock()
            if case .resolved = outcome {
                resetResolved = true
            }
            finished.append("reset")
            lock.unlock()
            done.fulfill()
        }
        plugin.dispatchEngineMethod("current", [:]) { _ in
            lock.lock()
            finished.append("current")
            lock.unlock()
            done.fulfill()
        }
        wait(for: [done], timeout: 6)
        lock.lock()
        defer { lock.unlock() }
        XCTAssertTrue(resetResolved, "\(finished)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "well before the 8 s appReadyTimeout")
        XCTAssertEqual(Set(finished), ["reset", "notifyAppReady", "current"])
    }
}
