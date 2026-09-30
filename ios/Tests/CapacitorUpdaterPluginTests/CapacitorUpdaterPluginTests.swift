import XCTest
@testable import CapacitorUpdaterPlugin
import Capacitor

/// Glue tests: the updater logic itself is tested in `core/tests` (Rust).
/// These cover what the iOS host adds: storage conversions, the engine binding,
/// method forwarding, hooks and events, and the WebView / splash helpers.
class CapacitorUpdaterTests: XCTestCase {
    private var plugin: CapacitorUpdaterPlugin!
    private var implementation: CapgoUpdater!
    private var noBackupDir: URL!
    private let silentLogger = Logger(withTag: "CapacitorUpdaterTests", options: Logger.Options(level: .silent))

    override func setUp() {
        super.setUp()
        plugin = CapacitorUpdaterPlugin()
        implementation = CapgoUpdater()
        implementation.setLogger(silentLogger)
        implementation.appId = "com.capgo.ios.tests"
        implementation.deviceID = "ios-tests-device"
        implementation.versionBuild = "1.0.0"
        noBackupDir = FileManager.default.temporaryDirectory.appendingPathComponent("capgo-tests-\(UUID().uuidString)")
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
    @discardableResult
    private func loadEngine(config extra: [String: Any] = [:]) throws -> [String: Any] {
        var config: [String: Any] = [
            "autoUpdate": false,
            "updateUrl": "",
            "statsUrl": "",
            "channelUrl": ""
        ]
        config.merge(extra) { $1 }
        let engine = try XCTUnwrap(implementation.engine())
        return try engine.call("pluginLoad", [
            "config": config,
            "native": [
                "versionName": "1.0.0",
                "versionCode": "1",
                "noBackupDir": noBackupDir.path,
                "trackUncleanExits": false
            ]
        ])
    }

    // MARK: - Storage

    func testKvGetConvertsLegacyUserDefaultsValues() throws {
        XCTAssertEqual(CapgoUpdater.storedString("beta"), "beta")
        XCTAssertEqual(CapgoUpdater.storedString(true), "true")
        XCTAssertEqual(CapgoUpdater.storedString(false), "false")
        XCTAssertEqual(CapgoUpdater.storedString(NSNumber(value: 1_700_000_000_000 as Int64)), "1700000000000")
        XCTAssertEqual(CapgoUpdater.storedString(NSNumber(value: 1)), "1")
        XCTAssertEqual(CapgoUpdater.storedString(Data("{\"id\":\"abc\"}".utf8)), "{\"id\":\"abc\"}")

        let sessions = try XCTUnwrap(CapgoUpdater.storedString(["abc": ["name": "PR 1"]]))
        let decoded = try JSONSerialization.jsonObject(with: Data(sessions.utf8)) as? [String: [String: String]]
        XCTAssertEqual(decoded?["abc"]?["name"], "PR 1")
        XCTAssertEqual(CapgoUpdater.storedString(["a", "b"]), "[\"a\",\"b\"]")
    }

    func testLegacyKeyedBundleStatusIsMigratedForTheEngine() throws {
        let legacy = """
        {"downloaded":"1970-01-01T00:00:00.000Z","id":"test-id","version":"1.0.0","checksum":"abc123","status":{"SUCCESS":{}}}
        """
        let migrated = CapgoUpdater.migratedBundleRecord(legacy)
        let record = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(migrated.utf8)) as? [String: Any])
        XCTAssertEqual(record["status"] as? String, "success")
        XCTAssertEqual(record["id"] as? String, "test-id")
        let current = "{\"id\":\"x\",\"status\":\"pending\"}"
        XCTAssertEqual(CapgoUpdater.migratedBundleRecord(current), current)
    }

    func testKvRoundTripKeepsBundleRecordsAsData() {
        let key = "capgo-tests-\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key + "_info")
        }
        implementation.engineKvSet(key, "value")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "value")
        XCTAssertEqual(implementation.engineKvGet(key), "value")

        implementation.engineKvSet(key + "_info", "{\"id\":\"x\"}")
        XCTAssertNotNil(UserDefaults.standard.data(forKey: key + "_info"))
        XCTAssertEqual(implementation.engineKvGet(key + "_info"), "{\"id\":\"x\"}")

        UserDefaults.standard.set(true, forKey: key)
        XCTAssertEqual(implementation.engineKvGet(key), "true")
        implementation.engineKvSet(key, nil)
        XCTAssertNil(implementation.engineKvGet(key))
    }

    // MARK: - Bundle folders

    func testBundleDirectoryStaysInsideBundleRoot() throws {
        let root = implementation.libraryDir.appendingPathComponent(CapgoUpdater.bundleDirectory).standardizedFileURL.path
        let folder = try implementation.bundleDirectory(id: "abcdefghij")
        XCTAssertEqual(folder.standardizedFileURL.path, root + "/abcdefghij")
        XCTAssertThrowsError(try implementation.bundleDirectory(id: "../escape"))
        XCTAssertThrowsError(try implementation.bundleDirectory(id: "/etc"))
        XCTAssertThrowsError(try implementation.bundleDirectory(id: "."))
        XCTAssertThrowsError(try implementation.bundleDirectory(id: ""))
    }

    // MARK: - Engine binding

    func testPluginLoadReportsCurrentBundleAndPushesHostHooks() throws {
        var hooks: [String: [String: Any]] = [:]
        let lock = NSLock()
        implementation.onHook = { name, payload in
            lock.lock()
            hooks[name] = payload
            lock.unlock()
            return nil
        }
        let loaded = try loadEngine(config: ["shakeMenu": true, "shakeMenuGesture": "threeFingerPinch", "keepUrlPathAfterReload": true])

        XCTAssertEqual(loaded["appId"] as? String, "com.capgo.ios.tests")
        XCTAssertEqual(loaded["isBuiltin"] as? Bool, true)
        XCTAssertEqual((loaded["bundle"] as? [String: Any])?["id"] as? String, "builtin")
        XCTAssertEqual(loaded["autoUpdate"] as? String, "off")
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(hooks["keepUrlPath"]?["enabled"] as? Bool, true)
        XCTAssertEqual(hooks["shakeMenu"]?["enabled"] as? Bool, true)
        XCTAssertEqual(hooks["shakeMenu"]?["gesture"] as? String, "threeFingerPinch")
    }

    func testPluginLoadRejectsInvalidPublicKey() throws {
        let engine = try XCTUnwrap(implementation.engine())
        XCTAssertThrowsError(try engine.call("pluginLoad", [
            "config": ["publicKey": "not a key", "statsUrl": "", "updateUrl": ""],
            "native": ["versionName": "1.0.0", "versionCode": "1", "noBackupDir": noBackupDir.path]
        ]))
    }

    func testMethodsResolveAndRejectThroughTheEngine() throws {
        plugin.implementation = implementation
        try loadEngine()

        guard case .resolved(let current) = plugin.runEngineMethod("current", [:]) else {
            return XCTFail("current rejected")
        }
        let currentObject = try XCTUnwrap(current as? [String: Any])
        XCTAssertEqual((currentObject["bundle"] as? [String: Any])?["id"] as? String, "builtin")
        XCTAssertEqual(currentObject["native"] as? String, "1.0.0")

        guard case .resolved(let next) = plugin.runEngineMethod("getNextBundle", [:]) else {
            return XCTFail("getNextBundle rejected")
        }
        XCTAssertNil(next, "null resolves without data")

        guard case .rejected(let message, _, _) = plugin.runEngineMethod("setUpdateUrl", ["url": "https://example.com"]) else {
            return XCTFail("setUpdateUrl must be gated by allowModifyUrl")
        }
        XCTAssertTrue(message.contains("allowModifyUrl"))

        guard case .rejected(_, let code, let data) = plugin.runEngineMethod("setChannel", [:]) else {
            return XCTFail("setChannel without channel must reject")
        }
        XCTAssertEqual(code, "SETCHANNEL_INVALID_PARAMS")
        XCTAssertNotNil(data?["message"])
    }

    func testEngineMethodsCoverEveryRegisteredMethod() throws {
        let engine = try XCTUnwrap(implementation.engine())
        let engineMethods = Set(try XCTUnwrap(engine.callValue("pluginMethods") as? [String]))
        let native: Set<String> = [
            "getAppUpdateInfo", "openAppStore", "performImmediateUpdate", "startFlexibleUpdate", "completeFlexibleUpdate"
        ]
        let registered = Set(plugin.pluginMethods.map(\.name))
        XCTAssertEqual(registered.subtracting(native), engineMethods)
        for name in engineMethods {
            XCTAssertTrue(plugin.responds(to: Selector("\(name):")), "\(name) is not exposed to Capacitor")
        }
    }

    func testShakeMenuSettersReachTheHostHook() throws {
        plugin.implementation = implementation
        var shakeMenuHooks: [[String: Any]] = []
        let lock = NSLock()
        implementation.onHook = { name, payload in
            if name == "shakeMenu" {
                lock.lock()
                shakeMenuHooks.append(payload)
                lock.unlock()
            }
            return nil
        }
        try loadEngine()
        guard case .resolved = plugin.runEngineMethod("setShakeChannelSelector", ["enabled": true]) else {
            return XCTFail("setShakeChannelSelector rejected")
        }
        guard case .resolved(let state) = plugin.runEngineMethod("isShakeChannelSelectorEnabled", [:]) else {
            return XCTFail("isShakeChannelSelectorEnabled rejected")
        }
        XCTAssertEqual((state as? [String: Any])?["enabled"] as? Bool, true)
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(shakeMenuHooks.last?["channelSelector"] as? Bool, true)
    }

    func testEngineEventsAreForwarded() throws {
        var events: [String] = []
        let lock = NSLock()
        implementation.onEvent = { name, _ in
            lock.lock()
            events.append(name)
            lock.unlock()
        }
        try loadEngine()
        let engine = try XCTUnwrap(implementation.engine())
        // The first appReady waits for the initial page to confirm itself.
        _ = try engine.call("pluginMethod", ["name": "notifyAppReady", "args": [:]])
        _ = try engine.call("appForeground")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            lock.lock()
            let ready = events.contains("appReady")
            lock.unlock()
            if ready {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        lock.lock()
        defer { lock.unlock() }
        XCTAssertTrue(events.contains("appReady"), "\(events)")
    }

    // MARK: - WebView scripts

    func testReadyGenerationScriptStampsNotifyAppReady() {
        let script = CapacitorUpdaterPlugin.readyGenerationScript(2)
        XCTAssertTrue(script.contains("window.__CAPGO_READY_GEN=2"))
        XCTAssertTrue(script.contains("cap.nativePromise"))
        XCTAssertTrue(script.contains("next.loadGeneration=window.__CAPGO_READY_GEN"))
        XCTAssertFalse(script.contains("plugin.notifyAppReady="))
    }

    func testWebViewStatsReporterScriptCapturesRuntimeAndRestartSignals() {
        let script = WebViewStatsReporter.script

        XCTAssertTrue(script.contains("unhandledrejection"))
        XCTAssertTrue(script.contains("resource_error"))
        XCTAssertTrue(script.contains("securitypolicyviolation"))
        XCTAssertTrue(script.contains("webview_unclean_restart"))
        XCTAssertTrue(script.contains("webview_dom_content_loaded"))
        XCTAssertTrue(script.contains("webview_page_loaded"))
        XCTAssertTrue(script.contains("reportWebViewError"))
    }

    // MARK: - Splash screen

    func testShowSplashscreenOptionsDisableAutoHide() {
        let options = plugin.splashscreenOptionsForTesting(methodName: "show")

        XCTAssertEqual(options["autoHide"] as? Bool, false)
        XCTAssertEqual(options["fadeInDuration"] as? Int, 0)
    }

    func testHideSplashscreenOptionsStayEmpty() {
        XCTAssertTrue(plugin.splashscreenOptionsForTesting(methodName: "hide").isEmpty)
    }

    func testSplashscreenInvocationTokenRejectsStaleRequests() {
        XCTAssertTrue(plugin.isCurrentSplashscreenInvocationTokenForTesting(0))

        plugin.advanceSplashscreenInvocationTokenForTesting()

        XCTAssertFalse(plugin.isCurrentSplashscreenInvocationTokenForTesting(0))
    }

    // MARK: - Logger

    func testLoggerInitialization() {
        let logger = Logger(withTag: "TestTag")
        logger.debug("Debug message")
        logger.info("Info message")
        logger.error("Error message")
    }
}
