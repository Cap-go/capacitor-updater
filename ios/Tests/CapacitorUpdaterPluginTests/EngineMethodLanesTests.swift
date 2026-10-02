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

    /// The lane waits until a detached method waits (releaseMethodLane) or returns: what it changes
    /// first happens in call order, before the calls that follow it (set then reset, set then current).
    func testDetachedMethodsTakeEffectInCallOrder() {
        let lanes = EngineMethodLanes()
        lanes.setDetachedMethods(["detached"])
        // Two thirds detached: below maxDetached, so each one starts at once.
        let calls = EngineMethodLanes.maxDetached * 3 / 2 - 1
        var seen: [String] = []
        let lock = NSLock()
        let done = expectation(description: "every call")
        done.expectedFulfillmentCount = calls
        for call in 0..<calls {
            let lane = call % 3 == 0
            let label = (lane ? "lane " : "detached ") + String(call)
            lanes.submit(lane ? "current" : "detached") {
                lock.lock()
                seen.append(label)
                lock.unlock()
                if !lane {
                    // The engine's releaseMethodLane hook, then the wait (network, notifyAppReady).
                    EngineMethodLanes.releaseCurrentThread()
                    Thread.sleep(forTimeInterval: 0.2)
                }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 20)
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(seen, (0..<calls).map { ($0 % 3 == 0 ? "lane " : "detached ") + String($0) })
    }

    /// At most maxDetached detached methods run; more queue without holding up the lane (notifyAppReady).
    func testDetachedMethodsAreBoundedAndNeverBlockTheLane() {
        let lanes = EngineMethodLanes()
        lanes.setDetachedMethods(["detached"])
        let calls = EngineMethodLanes.maxDetached * 3
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var (running, peak) = (0, 0)
        let saturated = expectation(description: "every slot busy")
        saturated.expectedFulfillmentCount = EngineMethodLanes.maxDetached
        saturated.assertForOverFulfill = false
        let done = expectation(description: "every call")
        done.expectedFulfillmentCount = calls
        let task = {
            lock.lock()
            running += 1
            peak = max(peak, running)
            lock.unlock()
            EngineMethodLanes.releaseCurrentThread()
            saturated.fulfill()
            release.wait()
            lock.lock()
            running -= 1
            lock.unlock()
            done.fulfill()
        }
        for _ in 0..<calls {
            lanes.submit("detached", task)
        }
        wait(for: [saturated], timeout: 10)
        let started = Date()
        let laneRan = expectation(description: "lane method")
        lanes.submit("notifyAppReady") { laneRan.fulfill() }
        wait(for: [laneRan], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "queued methods do not hold the lane")
        lock.lock()
        XCTAssertEqual(running, EngineMethodLanes.maxDetached)
        lock.unlock()
        for _ in 0..<calls {
            release.signal()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(peak, EngineMethodLanes.maxDetached)
    }

    /// A detached method that never reports a wait holds the lane for the limit at most.
    func testLaneHoldIsBounded() {
        let lanes = EngineMethodLanes(laneHoldLimit: 0.2)
        lanes.setDetachedMethods(["detached"])
        let release = DispatchSemaphore(value: 0)
        lanes.submit("detached") { release.wait() }
        let started = Date()
        let laneRan = expectation(description: "lane method")
        lanes.submit("current") { laneRan.fulfill() }
        wait(for: [laneRan], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "the lane waits at most its 0.2 s hold limit")
        release.signal()
    }
}
