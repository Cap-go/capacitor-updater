/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Network
import UIKit

/// iOS host of the shared Rust updater engine (`core/src/engine`).
///
/// The engine owns every updater decision (update cycle, bundle store, downloads,
/// channels, previews, stats). This class creates it and provides the platform
/// services it calls back into: UserDefaults storage, logs, background tasks and
/// backup exclusion. Events and UI hooks are forwarded to the plugin.
@objc public class CapgoUpdater: NSObject, CapgoEngineHost {
    private var logger: Logger?

    private let versionCode: String = Bundle.main.versionCode ?? ""
    private let versionOs = UIDevice.current.systemVersion
    let libraryDir: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
    static let bundleDirectory = "NoCloud/ionic_built_snapshots"
    private static let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
    let cacheFolder: URL = CapgoUpdater.cachesDir.appendingPathComponent("capgo_downloads")

    public var appId: String = ""
    public var deviceID = ""
    public var pluginVersion: String = ""
    /// Builtin bundle version name (config `version` or CFBundleShortVersionString).
    public var versionBuild: String = ""
    /// Tests point the builtin web assets somewhere else.
    var builtinFolderOverride: URL?

    /// JavaScript events emitted by the engine.
    var onEvent: ((String, [String: Any]) -> Void)?
    /// Engine hooks that need the Capacitor bridge or UI.
    var onHook: ((String, [String: Any]) -> [String: Any]?)?

    private let engineLock = NSLock()
    private var engineInstance: CapgoEngine?
    private let backgroundTasksLock = NSLock()
    private var backgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]

    public func setLogger(_ logger: Logger) {
        self.logger = logger
    }

    // MARK: - Device facts

    private var isDevEnvironment: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private func isEmulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private func hasEmbeddedMobileProvision() -> Bool {
        Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
    }

    private func isAppStoreReceiptSandbox() -> Bool {
        !isEmulator() && Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    private func isProd() -> Bool {
        !isDevEnvironment && !isAppStoreReceiptSandbox() && !hasEmbeddedMobileProvision()
    }

    private func installSource() -> String {
        if isEmulator() || isDevEnvironment || hasEmbeddedMobileProvision() {
            return ""
        }
        guard let receiptURL = Bundle.main.appStoreReceiptURL else {
            return ""
        }
        if receiptURL.lastPathComponent == "sandboxReceipt" {
            return "testflight"
        }
        return FileManager.default.fileExists(atPath: receiptURL.path) ? "app_store" : ""
    }

    func builtinFolderURL() -> URL {
        builtinFolderOverride ?? Bundle.main.bundleURL.appendingPathComponent("public")
    }

    /// Folder of a downloaded bundle; the id is confined to the bundle root by the core.
    func bundleDirectory(id: String) throws -> URL {
        let root = libraryDir.appendingPathComponent(Self.bundleDirectory).standardizedFileURL.path
        let result = try CapgoCore.call("resolvePathInside", ["base": root, "path": id])
        guard let path = result["path"] as? String else {
            throw CapgoCore.Failure(code: "path_traversal", message: "Invalid bundle id")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - Engine

    /// The engine, created on first use with the current device facts.
    func engine() -> CapgoEngine? {
        engineLock.lock()
        defer { engineLock.unlock() }
        if let engine = engineInstance {
            return engine
        }
        let config: [String: Any] = [
            "platform": "ios",
            "appId": appId,
            "pluginVersion": pluginVersion,
            "versionBuild": versionBuild,
            "versionCode": versionCode,
            "versionOs": versionOs,
            "deviceId": deviceID,
            "isEmulator": isEmulator(),
            "isProd": isProd(),
            "installSource": installSource(),
            "bundleRoot": libraryDir.appendingPathComponent(Self.bundleDirectory).path,
            "storageRoot": libraryDir.path,
            "statsDir": libraryDir.path,
            "cacheDir": cacheFolder.path,
            "builtinDir": builtinFolderURL().path,
            "builtinServerPath": "",
            "keys": ["serverPath": "serverBasePath"]
        ]
        engineInstance = CapgoEngine(config: config, host: self)
        if engineInstance == nil {
            logger?.error("Capgo updater engine could not be created")
        }
        DispatchQueue.global(qos: .utility).async { Self.removeLegacyDownloadTempFiles() }
        return engineInstance
    }

    /// Plugin versions before the Rust engine downloaded into Documents/package_<id>.tmp and
    /// update_<id>.dat; one left by an interrupted download would otherwise stay forever.
    static func removeLegacyDownloadTempFiles(in directory: URL? = nil) {
        let fileManager = FileManager.default
        guard let documents = directory ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
              let contents = try? fileManager.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil) else {
            return
        }
        for url in contents {
            let name = url.lastPathComponent
            if (name.hasPrefix("package_") && name.hasSuffix(".tmp")) || (name.hasPrefix("update_") && name.hasSuffix(".dat")) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Flushes queued stats before the plugin goes away.
    public func shutdown() {
        engineLock.lock()
        let engine = engineInstance
        engineLock.unlock()
        _ = try? engine?.call("statsShutdown")
    }

    // MARK: CapgoEngineHost

    func engineLog(level: Int32, message: String) {
        guard let logger else {
            return
        }
        switch level {
        case 0:
            logger.debug(message)
        case 1:
            logger.info(message)
        case 2:
            logger.warn(message)
        default:
            logger.error(message)
        }
    }

    /// Every stored value as the string the engine expects. Older plugin versions
    /// stored booleans, numbers, dictionaries and Codable Data in UserDefaults.
    func engineKvGet(_ key: String) -> String? {
        guard let value = UserDefaults.standard.object(forKey: key) else {
            return nil
        }
        let stored = Self.storedString(value)
        if key.hasSuffix("_info") || key == "CapacitorUpdater.lastFailedBundle" {
            return stored.map(Self.migratedBundleRecord)
        }
        return stored
    }

    /// Old iOS versions encoded the bundle status as a keyed enum (`{"SUCCESS":{}}`);
    /// the engine reads the plain stored value (`"success"`).
    static func migratedBundleRecord(_ json: String) -> String {
        guard var record = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let status = record["status"] as? [String: Any],
              status.count == 1,
              let legacy = status.keys.first else {
            return json
        }
        record["status"] = legacy.lowercased()
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              let migrated = String(data: data, encoding: .utf8) else {
            return json
        }
        return migrated
    }

    static func storedString(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let data as Data:
            return String(data: data, encoding: .utf8)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        case let date as Date:
            return String(Int64(date.timeIntervalSince1970 * 1000))
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }

    func engineKvSet(_ key: String, _ value: String?) {
        let defaults = UserDefaults.standard
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(Self.legacyTypedValue(key, value), forKey: key)
    }

    /// Keys earlier plugin versions stored with another type (Bool, Int64, a dictionary, Codable Data):
    /// keep that type so a downgrade still reads them. Everything else is a string.
    private static let boolKeys: Set<String> = [
        "CapacitorUpdater.previewSession",
        "CapacitorUpdater.previewSessionAlertPending",
        "CapacitorUpdater.defaultChannelInstallMarkerCreated",
        "CapacitorUpdater.previewPreviousShakeMenu",
        "CapacitorUpdater.previewPreviousShakeChannelSelector",
        "CapacitorUpdater.previewPreviousDefaultChannelWasSet",
        "CapacitorUpdater.appSessionForeground"
    ]

    static func legacyTypedValue(_ key: String, _ value: String) -> Any {
        // Bundle records (and the last failed bundle) have always been JSON Data (Codable).
        if key.hasSuffix("_info") || key == "CapacitorUpdater.lastFailedBundle" {
            return Data(value.utf8)
        }
        if boolKeys.contains(key), value == "true" || value == "false" {
            return value == "true"
        }
        if key == "BACKGROUND_TIMESTAMP_KEY_CAPGO", let timestamp = Int64(value) {
            return NSNumber(value: timestamp)
        }
        if key == "CapacitorUpdater.previewSessions",
           let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] {
            return object
        }
        return value
    }

    func engineKvKeys() -> [String] {
        Array(UserDefaults.standard.dictionaryRepresentation().keys)
    }

    func engineEmit(_ event: String, _ payload: [String: Any]) {
        // `statsSent` acknowledges host stats callbacks; this host registers none.
        guard event != "statsSent" else {
            return
        }
        onEvent?(event, payload)
    }

    func engineHook(_ name: String, _ payload: [String: Any]) -> [String: Any]? {
        switch name {
        case "backgroundTask":
            updateBackgroundTask(action: payload["action"] as? String ?? "", name: payload["name"] as? String ?? "")
            return nil
        case "excludeFromBackup":
            excludeFromBackup(path: payload["path"] as? String ?? "")
            return nil
        case "cleartextPermitted":
            let ats = Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any]
            return ["permitted": Self.atsAllowsCleartext(host: payload["host"] as? String ?? "", ats: ats)]
        default:
            return onHook?(name, payload)
        }
    }

    // MARK: - Platform services

    /// App Transport Security decision for plain HTTP to `host` (the engine's HTTP client
    /// is not URLSession, so it applies the app's ATS settings itself), with Apple's precedence:
    /// - `NSAllowsArbitraryLoads` is ignored when `NSAllowsArbitraryLoadsInWebContent`,
    ///   `NSAllowsArbitraryLoadsForMedia` or `NSAllowsLocalNetworking` is present (any value).
    /// - A matching exception domain (the most specific one) overrides the global settings.
    /// - IP addresses cannot be exception domains: only local networking or arbitrary loads allow them.
    static func atsAllowsCleartext(host: String, ats: [String: Any]?) -> Bool {
        let host = host.lowercased()
        // ATS always allows localhost.
        if host == "localhost" {
            return true
        }
        let ats = ats ?? [:]
        let fineGrainedKeys = ["NSAllowsArbitraryLoadsInWebContent", "NSAllowsArbitraryLoadsForMedia", "NSAllowsLocalNetworking"]
        let hasFineGrainedKey = fineGrainedKeys.contains { ats[$0] != nil }
        let allowsArbitraryLoads = !hasFineGrainedKey && ats["NSAllowsArbitraryLoads"] as? Bool == true
        let allowsLocalNetworking = ats["NSAllowsLocalNetworking"] as? Bool == true
        let unbracketed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if IPv4Address(host) != nil || IPv6Address(unbracketed) != nil {
            return allowsLocalNetworking || allowsArbitraryLoads
        }
        let exceptions = ats["NSExceptionDomains"] as? [String: [String: Any]] ?? [:]
        let match = exceptions
            .map { (domain: $0.key.lowercased(), settings: $0.value) }
            .filter { entry in
                host == entry.domain
                    || (entry.settings["NSIncludesSubdomains"] as? Bool == true && host.hasSuffix("." + entry.domain))
            }
            .max { $0.domain.count < $1.domain.count }
        if let settings = match?.settings {
            return settings["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true
                || settings["NSTemporaryExceptionAllowsInsecureHTTPLoads"] as? Bool == true
        }
        if allowsLocalNetworking && (!host.contains(".") || host.hasSuffix(".local")) {
            return true
        }
        return allowsArbitraryLoads
    }

    private func updateBackgroundTask(action: String, name: String) {
        backgroundTasksLock.lock()
        let existing = backgroundTasks.removeValue(forKey: name)
        backgroundTasksLock.unlock()
        if let existing, existing != .invalid {
            UIApplication.shared.endBackgroundTask(existing)
        }
        guard action == "begin" else {
            return
        }
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.updateBackgroundTask(action: "end", name: name)
        }
        backgroundTasksLock.lock()
        backgroundTasks[name] = identifier
        backgroundTasksLock.unlock()
    }

    private func excludeFromBackup(path: String) {
        guard !path.isEmpty else {
            return
        }
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            logger?.warn("Cannot exclude \(url.lastPathComponent) from backup: \(error.localizedDescription)")
        }
    }
}

extension Bundle {
    var versionName: String? {
        infoDictionary?["CFBundleShortVersionString"] as? String
    }
    var versionCode: String? {
        infoDictionary?["CFBundleVersion"] as? String
    }
}
