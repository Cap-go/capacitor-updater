/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import UIKit

/// iOS host of the shared Rust updater engine (`core/src/engine`).
///
/// Bundle store, backend client, stats, downloads (transfer, resume, verification,
/// decryption, extraction) all run in the engine; this class keeps the plugin-facing
/// Swift API, provides the platform services (UserDefaults, logs, events) and
/// converts engine JSON into the plugin's Swift types.
@objc public class CapgoUpdater: NSObject, CapgoEngineHost {
    private var logger: Logger!

    private let versionCode: String = Bundle.main.versionCode ?? ""
    private let versionOs = UIDevice.current.systemVersion
    private let libraryDir: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
    private let bundleDirectory: String = "NoCloud/ionic_built_snapshots"
    private let cacheFolder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("capgo_downloads")

    /// HTTP + decode share one pool. Cap by CPU: 8 on 4 cores, 16 on 8 cores, 64 max.
    static let manifestMaxConcurrentFiles = clampedManifestConcurrency(processorCount: ProcessInfo.processInfo.processorCount)
    static let maxPendingStats = 200
    static let statsFlushInterval: TimeInterval = 1.0

    static func clampedManifestConcurrency(processorCount: Int) -> Int {
        CapgoCore.int("manifestConcurrency", ["processorCount": processorCount], "maxConcurrentFiles", fallback: 8)
    }

    public let CAP_SERVER_PATH: String = "serverBasePath"
    public var versionBuild: String = ""
    public var customId: String = ""
    public var pluginVersion: String = ""
    public var timeout: Double = 20
    public var statsUrl: String = ""
    /// Optional gate run before any download touches disk (e.g. wait for launch cleanup).
    public var beforeDownload: (() throws -> Void)?
    public var channelUrl: String = ""
    public var defaultChannel: String = ""
    public var appId: String = ""
    public var deviceID = ""
    public var previewSession = false
    public var publicKey: String = ""
    /// Off by default: a redirect must never downgrade updater traffic from HTTPS to plain HTTP.
    public var allowHttpsToHttpRedirect = false
    /// Tests point the builtin web assets somewhere else.
    var builtinFolderOverride: URL?

    private var cachedKeyId: String?
    private let engineLock = NSLock()
    private var engineInstance: CapgoEngine?
    private var engineConfigSnapshot: String = ""
    private var statsCallbacks: [String: () -> Void] = [:]
    private let statsCallbacksLock = NSLock()

    static func buildUserAgent(appId: String, pluginVersion: String, versionOs: String) -> String {
        CapgoCore.string(
            "userAgent",
            ["appId": appId, "pluginVersion": pluginVersion, "versionOs": versionOs, "platform": "ios"],
            "userAgent",
            fallback: "CapacitorUpdater/unknown (unknown) ios/unknown"
        )
    }

    enum SecurePathError: Error {
        case emptyPath
        case windowsPath
        case absolutePath
        case pathTraversal
    }

    // MARK: - Shared core rules (thin delegates)

    static func containsPathTraversalSegment(_ relativePath: String) -> Bool {
        CapgoCore.bool("pathTraversalSegment", ["path": relativePath], "traversal", fallback: true)
    }

    /// Resolves an untrusted relative path (manifest file_name, zip entry, bundle id)
    /// strictly inside `baseDirectory`. The guard lives in the shared Rust core.
    static func resolvePathInsideDirectory(baseDirectory: URL, relativePath: String) throws -> URL {
        try resolveInsideDirectory("resolvePathInside", baseDirectory: baseDirectory, input: ["path": relativePath])
    }

    static func resolveBundleDirectory(libraryDir: URL, bundleId: String) throws -> URL {
        let bundleRoot = libraryDir.appendingPathComponent("NoCloud/ionic_built_snapshots")
        return try resolvePathInsideDirectory(baseDirectory: bundleRoot, relativePath: bundleId)
    }

    static func resolveManifestTargetPath(baseDirectory: URL, fileName: String) throws -> URL {
        try resolveInsideDirectory("manifestTargetPath", baseDirectory: baseDirectory, input: ["fileName": fileName])
    }

    private static func resolveInsideDirectory(_ operation: String, baseDirectory: URL, input: [String: Any?]) throws -> URL {
        var request = input
        request["base"] = baseDirectory.standardizedFileURL.path
        do {
            let result = try CapgoCore.call(operation, request)
            guard let path = result["path"] as? String else {
                throw SecurePathError.pathTraversal
            }
            return URL(fileURLWithPath: path, isDirectory: false)
        } catch let failure as CapgoCore.Failure {
            switch failure.code {
            case "empty_path":
                throw SecurePathError.emptyPath
            case "invalid_separator":
                throw SecurePathError.windowsPath
            case "absolute_path":
                throw SecurePathError.absolutePath
            default:
                throw SecurePathError.pathTraversal
            }
        }
    }

    static func rememberManifestTarget(_ seenTargets: inout Set<String>, targetFile: URL) -> Bool {
        seenTargets.insert(targetFile.standardizedFileURL.path).inserted
    }

    static func shouldAppendHttpBody(statusCode: Int, existingBytes: Int64) -> Bool {
        CapgoCore.bool("appendHttpBody", ["statusCode": statusCode, "existingBytes": existingBytes], "append")
    }

    static func safePartialToken(_ fileName: String) -> String {
        CryptoCipher.shortPathKey(fileName)
    }

    static func manifestPartialURL(cacheFolder: URL, hash: String, fileName: String) -> URL {
        let name = CapgoCore.string(
            "manifestPartialName",
            ["hash": hash, "fileName": fileName],
            "name",
            fallback: "partial_\(safePartialToken(fileName)).tmp"
        )
        return cacheFolder.appendingPathComponent(name)
    }

    static func parseRemoteError(data: Data?) -> (error: String, message: String) {
        let body = data.flatMap { String(data: $0, encoding: .utf8) }
        let result = (try? CapgoCore.call("remoteError", ["body": body])) ?? [:]
        return (result["error"] as? String ?? "", result["message"] as? String ?? "")
    }

    /// Epoch ms until which requests stay blocked after a 429 (0 = no block).
    static func resolveRateLimitBlockedUntilMs(retryAfterHeader: String?, data: Data?, nowMs: Double) -> Double {
        let body = data.flatMap { String(data: $0, encoding: .utf8) }
        let blockedUntil = CapgoCore.value(
            "rateLimitDeadline",
            ["retryAfter": retryAfterHeader, "body": body, "nowMs": Int64(nowMs)],
            "blockedUntilMs",
            fallback: NSNumber(value: 0)
        )
        return blockedUntil.doubleValue
    }

    static func isReusableCacheFile(_ url: URL, expectedHash: String) -> Bool {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return CapgoCore.bool("reusableCacheFile", ["hash": expectedHash, "size": size], "reusable")
    }

    static func isSafeCacheHash(_ hash: String) -> Bool {
        CapgoCore.bool("safeCacheHash", ["hash": hash], "safe")
    }

    static func isTransientStatsFailure(_ statusCode: Int) -> Bool {
        CapgoCore.bool("retryableHttpStatus", ["status": statusCode], "retryable")
    }

    static func shouldResetForForeignBundle(bundlePath: String?, isBuiltin: Bool, hasStoredBundleInfo: Bool) -> Bool {
        CapgoCore.bool(
            "foreignBundleReset",
            ["bundlePath": bundlePath, "isBuiltin": isBuiltin, "hasStoredBundleInfo": hasStoredBundleInfo],
            "reset"
        )
    }

    // MARK: - Hooks set by the plugin

    public var notifyDownloadRaw: (String, Int, Bool, BundleInfo?) -> Void = { _, _, _, _  in }
    public func notifyDownload(id: String, percent: Int, ignoreMultipleOfTen: Bool = false, bundle: BundleInfo? = nil) {
        let emit = {
            self.notifyDownloadRaw(id, percent, ignoreMultipleOfTen, bundle)
        }
        if Thread.isMainThread {
            emit()
        } else {
            DispatchQueue.main.async {
                emit()
            }
        }
    }
    public var notifyDownload: (String, Int) -> Void = { _, _  in }
    public var notifyListeners: (String, [String: Any]) -> Void = { _, _ in }

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

    private func isProd() -> Bool {
        return !self.isDevEnvironment && !self.isAppStoreReceiptSandbox() && !self.hasEmbeddedMobileProvision()
    }

    private func installSource() -> String? {
        if isEmulator() || self.isDevEnvironment || self.hasEmbeddedMobileProvision() {
            return nil
        }
        guard let receiptURL = Bundle.main.appStoreReceiptURL else {
            return nil
        }
        if receiptURL.lastPathComponent == "sandboxReceipt" {
            return "testflight"
        }
        guard FileManager.default.fileExists(atPath: receiptURL.path) else {
            return nil
        }
        return "app_store"
    }

    private func hasEmbeddedMobileProvision() -> Bool {
        Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
    }

    private func isAppStoreReceiptSandbox() -> Bool {
        if isEmulator() {
            return false
        }
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    private func isEmulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    func builtinFolderURL() -> URL {
        builtinFolderOverride ?? Bundle.main.bundleURL.appendingPathComponent("public")
    }

    // MARK: - Engine

    private func runtimeConfig() -> [String: Any] {
        [
            "platform": "ios",
            "appId": appId,
            "pluginVersion": pluginVersion,
            "versionBuild": versionBuild,
            "versionCode": versionCode,
            "versionOs": versionOs,
            "deviceId": deviceID,
            "customId": customId,
            "defaultChannel": defaultChannel,
            "isEmulator": isEmulator(),
            "isProd": isProd(),
            "installSource": installSource() ?? "",
            "statsUrl": statsUrl,
            "channelUrl": channelUrl,
            "publicKey": publicKey,
            "previewSession": previewSession,
            "timeoutMs": Int((timeout > 0 ? timeout : 20) * 1000),
            "allowHttpsToHttpRedirect": allowHttpsToHttpRedirect
        ]
    }

    private static func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return ""
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// The engine for the current fields: created lazily, re-configured when a field changes.
    func engine() -> CapgoEngine? {
        engineLock.lock()
        defer { engineLock.unlock() }
        let runtime = runtimeConfig()
        let snapshot = Self.json(runtime)
        if let engine = engineInstance {
            if snapshot != engineConfigSnapshot {
                do {
                    _ = try engine.call("configure", runtime)
                } catch {
                    logger?.error("Failed to configure updater engine: \(error)")
                }
                engineConfigSnapshot = snapshot
            }
            return engine
        }
        var config = runtime
        config["bundleRoot"] = libraryDir.appendingPathComponent(bundleDirectory).path
        config["storageRoot"] = libraryDir.path
        config["statsDir"] = libraryDir.path
        config["cacheDir"] = cacheFolder.path
        config["builtinDir"] = builtinFolderURL().path
        config["builtinServerPath"] = ""
        config["keys"] = ["serverPath": CAP_SERVER_PATH]
        engineInstance = CapgoEngine(config: config, host: self)
        engineConfigSnapshot = snapshot
        if engineInstance == nil {
            logger?.error("Capgo updater engine could not be created")
        }
        return engineInstance
    }

    @discardableResult
    private func call(_ operation: String, _ input: [String: Any?] = [:]) -> [String: Any] {
        engine()?.callUnchecked(operation, input) ?? [:]
    }

    private func callValue(_ operation: String, _ input: [String: Any?] = [:]) -> Any {
        engine()?.callValueUnchecked(operation, input) ?? NSNull()
    }

    private func bundleCall(_ operation: String, _ input: [String: Any?] = [:]) -> BundleInfo? {
        (callValue(operation, input) as? [String: Any]).map(BundleInfo.fromRaw)
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

    func engineKvGet(_ key: String) -> String? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key) {
            return String(data: data, encoding: .utf8)
        }
        return defaults.string(forKey: key)
    }

    func engineKvSet(_ key: String, _ value: String?) {
        let defaults = UserDefaults.standard
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        // Bundle records have always been stored as JSON Data (Codable); keep the format.
        if key.hasSuffix("_info") {
            defaults.set(Data(value.utf8), forKey: key)
        } else {
            defaults.set(value, forKey: key)
        }
    }

    func engineKvKeys() -> [String] {
        Array(UserDefaults.standard.dictionaryRepresentation().keys)
    }

    func engineEmit(_ event: String, _ payload: [String: Any]) {
        switch event {
        case "downloadProgress":
            notifyDownload(id: payload["id"] as? String ?? "", percent: payload["percent"] as? Int ?? 0)
        case "statsSent":
            guard let callbackId = payload["callbackId"] as? String else {
                return
            }
            statsCallbacksLock.lock()
            let callback = statsCallbacks.removeValue(forKey: callbackId)
            statsCallbacksLock.unlock()
            callback?()
        default:
            notifyListeners(event, payload)
        }
    }

    func engineHook(_ name: String, _ payload: [String: Any]) -> [String: Any]? {
        switch name {
        case "sendStats":
            // Route engine statistics through the overridable sendStats.
            sendStats(
                action: payload["action"] as? String ?? "",
                versionName: payload["versionName"] as? String,
                oldVersionName: payload["oldVersionName"] as? String ?? ""
            )
            return ["handled": true]
        case "beforeDownload":
            do {
                try beforeDownload?()
                return nil
            } catch {
                return ["error": error.localizedDescription]
            }
        default:
            return nil
        }
    }

    // MARK: - Lifecycle

    public func shutdown() {
        if engineInstance != nil {
            call("statsShutdown")
        }
    }

    public func setPublicKey(_ publicKey: String) {
        // Empty string means no encryption - proceed normally
        if publicKey.isEmpty {
            self.publicKey = ""
            self.cachedKeyId = nil
            return
        }
        // Non-empty: must be a valid RSA key or crash
        guard RSAPublicKey.load(rsaPublicKey: publicKey) != nil else {
            fatalError("Invalid public key in capacitor.config.json: failed to parse RSA key. Remove the key or provide a valid PEM-formatted RSA public key.")
        }
        self.publicKey = publicKey
        self.cachedKeyId = CryptoCipher.calcKeyId(publicKey: publicKey)
    }

    public func getKeyId() -> String? {
        return self.cachedKeyId
    }

    // MARK: - Downloads

    private func manifestDicts(_ manifest: [ManifestEntry]) -> [[String: Any]] {
        manifest.map { entry in
            var dict: [String: Any] = [:]
            if let fileName = entry.file_name {
                dict["file_name"] = fileName
            }
            if let fileHash = entry.file_hash {
                dict["file_hash"] = fileHash
            }
            if let downloadUrl = entry.download_url {
                dict["download_url"] = downloadUrl
            }
            return dict
        }
    }

    private static func manifestEntry(_ dict: [String: Any]) -> ManifestEntry {
        ManifestEntry(
            file_name: dict["file_name"] as? String,
            file_hash: dict["file_hash"] as? String,
            download_url: dict["download_url"] as? String
        )
    }

    private func engineDownload(_ input: [String: Any?]) throws -> BundleInfo {
        guard let engine = engine() else {
            throw NSError(domain: "CapgoUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: "Updater engine unavailable"])
        }
        var request = input
        // The plugin layer reports updateAvailable / downloadFailed itself on iOS.
        request["emitEvents"] = false
        do {
            let result = try engine.call("download", request)
            return BundleInfo.fromRaw(result)
        } catch let failure as CapgoCore.Failure {
            throw NSError(domain: "CapgoUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: failure.message, "code": failure.code])
        }
    }

    /// Downloads, verifies (checksum before extraction), decrypts and installs a zip bundle.
    public func download(
        url: URL,
        version: String,
        sessionKey: String,
        checksum: String,
        link: String? = nil,
        comment: String? = nil
    ) throws -> BundleInfo {
        try engineDownload([
            "url": url.absoluteString,
            "version": version,
            "sessionKey": sessionKey,
            "checksum": checksum,
            "link": link,
            "comment": comment
        ])
    }

    public func downloadManifest(
        manifest: [ManifestEntry],
        version: String,
        sessionKey: String,
        link: String? = nil,
        comment: String? = nil
    ) throws -> BundleInfo {
        try engineDownload([
            "version": version,
            "sessionKey": sessionKey,
            "manifest": manifestDicts(manifest),
            "link": link,
            "comment": comment
        ])
    }

    public func getMissingBundleFiles(manifest: [ManifestEntry], sessionKey: String) -> [ManifestEntry] {
        let result = missingBundleFilesResult(manifest: manifest, sessionKey: sessionKey)
        return (result["missing"] as? [[String: Any]] ?? []).map(Self.manifestEntry)
    }

    public func missingBundleFilesResult(manifest: [ManifestEntry], sessionKey: String) -> [String: Any] {
        call("missingBundleFiles", ["manifest": manifestDicts(manifest), "sessionKey": sessionKey])
    }

    public func getBundleDownloadSize(updateUrl: URL, version: String?, manifest: [ManifestEntry]) -> [String: Any] {
        call("bundleDownloadSize", ["updateUrl": updateUrl.absoluteString, "version": version, "manifest": manifestDicts(manifest)])
    }

    func populateDeltaCache(for id: String) {
        call("populateDeltaCache", ["id": id])
    }

    /// GET a JSON object through the engine HTTP client (preview payloads).
    func fetchJson(url: URL) throws -> [String: Any] {
        guard let engine = engine() else {
            throw NSError(domain: "CapgoUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: "Updater engine unavailable"])
        }
        do {
            return try engine.call("fetchJson", ["url": url.absoluteString])
        } catch let failure as CapgoCore.Failure {
            throw NSError(domain: "CapgoUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: failure.message])
        }
    }

    // MARK: - Backend

    public func getLatest(url: URL, channel: String?, appIdOverride: String? = nil) -> AppVersion {
        let result = call("getLatest", ["updateUrl": url.absoluteString, "channel": channel, "appId": appIdOverride])
        let latest = AppVersion()
        latest.url = result["url"] as? String ?? ""
        latest.checksum = result["checksum"] as? String ?? ""
        latest.version = result["version"] as? String ?? ""
        latest.major = result["major"] as? Bool
        latest.breaking = result["breaking"] as? Bool
        latest.error = result["error"] as? String
        latest.kind = result["kind"] as? String
        latest.message = result["message"] as? String
        latest.sessionKey = result["sessionKey"] as? String
        latest.data = result["data"] as? [String: String]
        latest.link = result["link"] as? String
        latest.comment = result["comment"] as? String
        latest.statusCode = result["statusCode"] as? Int ?? 0
        if let manifest = result["manifest"] as? [[String: Any]] {
            latest.manifest = manifest.map(Self.manifestEntry)
        }
        return latest
    }

    func unsetChannel(defaultChannelKey: String, configDefaultChannel: String, allowSetDefaultChannel: Bool) -> SetChannel {
        let result = call("unsetChannel", [
            "persistKey": defaultChannelKey,
            "configDefaultChannel": configDefaultChannel,
            "allowSetDefaultChannel": allowSetDefaultChannel
        ])
        if result["error"] == nil {
            self.defaultChannel = configDefaultChannel
        }
        return Self.setChannelResult(result)
    }

    func setChannel(channel: String, defaultChannelKey: String, allowSetDefaultChannel: Bool, configDefaultChannel: String = "") -> SetChannel {
        let result = call("setChannel", [
            "channel": channel,
            "persistKey": defaultChannelKey,
            "allowSetDefaultChannel": allowSetDefaultChannel,
            "configDefaultChannel": configDefaultChannel
        ])
        if result["error"] == nil {
            self.defaultChannel = result["unset"] as? Bool == true ? configDefaultChannel : channel
        }
        return Self.setChannelResult(result)
    }

    private static func setChannelResult(_ result: [String: Any]) -> SetChannel {
        let setChannel = SetChannel()
        setChannel.status = result["status"] as? String ?? ""
        setChannel.message = result["message"] as? String ?? ""
        setChannel.error = result["error"] as? String ?? ""
        return setChannel
    }

    func getChannel(defaultChannelKey: String? = nil) -> GetChannel {
        let result = call("getChannel", ["persistKey": defaultChannelKey])
        let getChannel = GetChannel()
        getChannel.channel = result["channel"] as? String ?? ""
        getChannel.status = result["status"] as? String ?? ""
        getChannel.message = result["message"] as? String ?? ""
        getChannel.error = result["error"] as? String ?? ""
        getChannel.allowSet = result["allowSet"] as? Bool ?? true
        if result["error"] == nil, let channel = result["channel"] as? String, !channel.isEmpty, channel != BundleInfo.ID_BUILTIN {
            self.defaultChannel = channel
        }
        return getChannel
    }

    func persistDefaultChannelFromResponse(channel: String?, defaultChannelKey: String?) {
        guard let channelName = channel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !channelName.isEmpty,
              channelName != BundleInfo.ID_BUILTIN else {
            return
        }
        self.defaultChannel = channelName
        if let defaultChannelKey, !defaultChannelKey.isEmpty {
            UserDefaults.standard.set(channelName, forKey: defaultChannelKey)
        }
        logger.info("defaultChannel synchronized from getChannel(): \(channelName)")
    }

    func listChannels() -> ListChannels {
        let result = call("listChannels")
        let listChannels = ListChannels()
        listChannels.channels = result["channels"] as? [[String: Any]] ?? []
        listChannels.error = result["error"] as? String ?? ""
        return listChannels
    }

    // MARK: - Stats

    func sendStats(action: String, versionName: String? = nil, oldVersionName: String? = "") {
        call("statsSend", ["action": action, "versionName": versionName, "oldVersionName": oldVersionName])
    }

    func sendStats(action: String, versionName: String?, oldVersionName: String?, metadata: [String: String]) {
        call("statsSend", ["action": action, "versionName": versionName, "oldVersionName": oldVersionName, "metadata": metadata])
    }

    func sendStats(action: String, versionName: String?, oldVersionName: String?, metadata: [String: String], onSent: @escaping () -> Void) {
        let callbackId = UUID().uuidString
        statsCallbacksLock.lock()
        statsCallbacks[callbackId] = onSent
        statsCallbacksLock.unlock()
        call("statsSend", [
            "action": action,
            "versionName": versionName,
            "oldVersionName": oldVersionName,
            "metadata": metadata,
            "callbackId": callbackId
        ])
    }

    func restorePendingStats() {
        call("statsRestore")
    }

    func persistPendingStats() {
        call("statsPersist")
    }

    // MARK: - Bundle store

    public func list(raw: Bool = false) -> [BundleInfo] {
        let bundles = callValue("bundleList", ["raw": raw]) as? [[String: Any]] ?? []
        return bundles.map(BundleInfo.fromRaw)
    }

    public func delete(id: String, removeInfo: Bool) -> Bool {
        call("bundleDelete", ["id": id, "removeInfo": removeInfo, "cancelActiveDownload": true])["deleted"] as? Bool ?? false
    }

    public func delete(id: String) -> Bool {
        delete(id: id, removeInfo: true)
    }

    public func drainPendingDeletes() {
        call("bundleDrainPendingDeletes")
    }

    public func cleanupDeltaCache() {
        call("bundleCleanupDeltaCache")
    }

    public func cleanupDeltaCache(threadToCheck: Thread?) {
        if threadToCheck?.isCancelled == true {
            return
        }
        cleanupDeltaCache()
    }

    public func cleanupDownloadDirectories(allowedIds: Set<String>) {
        call("bundleCleanupDownloadDirectories", ["allowedIds": Array(allowedIds)])
    }

    public func cleanupDownloadDirectories(allowedIds: Set<String>, threadToCheck: Thread?) {
        if threadToCheck?.isCancelled == true {
            logger.warn("cleanupDownloadDirectories was cancelled")
            return
        }
        cleanupDownloadDirectories(allowedIds: allowedIds)
    }

    public func allowedBundleIdsForCleanup() -> Set<String> {
        Set(callValue("bundleAllowedIdsForCleanup") as? [String] ?? [])
    }

    public func cleanupOrphanedTempFolders(threadToCheck: Thread?) {
        if threadToCheck?.isCancelled == true {
            logger.warn("cleanupOrphanedTempFolders was cancelled")
            return
        }
        call("bundleCleanupOrphanedTempFolders")
        call("cleanupDownloadTempFiles")
    }

    public func getBundleDirectory(id: String) throws -> URL {
        try Self.resolveBundleDirectory(libraryDir: libraryDir, bundleId: id)
    }

    struct ResetState {
        let currentBundlePath: String
        let fallbackBundleId: String
        let nextBundleId: String?
    }

    func captureResetState() -> ResetState {
        let state = call("bundleCaptureResetState")
        return ResetState(
            currentBundlePath: state["currentBundlePath"] as? String ?? "",
            fallbackBundleId: state["fallbackBundleId"] as? String ?? BundleInfo.ID_BUILTIN,
            nextBundleId: state["nextBundleId"] as? String
        )
    }

    func restoreResetState(_ state: ResetState) {
        call("bundleRestoreResetState", [
            "currentBundlePath": state.currentBundlePath,
            "fallbackBundleId": state.fallbackBundleId,
            "nextBundleId": state.nextBundleId
        ])
    }

    func prepareResetStateForTransition() {
        call("bundlePrepareResetTransition")
    }

    func finalizeResetTransition(previousBundleName: String, isInternal: Bool) {
        call("bundleFinalizeResetTransition", ["previousBundleName": previousBundleName, "internal": isInternal])
    }

    func canSet(bundle: BundleInfo) -> Bool {
        call("bundleCanSet", ["id": bundle.getId(), "bundle": bundle.toRaw()])["canSet"] as? Bool ?? false
    }

    public func set(bundle: BundleInfo) -> Bool {
        set(id: bundle.getId())
    }

    public func set(id: String) -> Bool {
        call("bundleSet", ["id": id])["set"] as? Bool ?? false
    }

    func stagePendingReload(bundle: BundleInfo) -> Bool {
        call("bundleStagePendingReload", ["id": bundle.getId(), "bundle": bundle.toRaw()])["staged"] as? Bool ?? false
    }

    func stagePreviewFallbackReload(bundle: BundleInfo) -> Bool {
        call("bundleStagePreviewFallbackReload", ["id": bundle.getId(), "bundle": bundle.toRaw()])["staged"] as? Bool ?? false
    }

    func finalizePendingReload(bundle: BundleInfo, previousBundleName: String) {
        call("bundleFinalizePendingReload", ["id": bundle.getId(), "bundle": bundle.toRaw(), "previousBundleName": previousBundleName])
    }

    public func autoReset() {
        autoReset(currentNativeBuildVersion: versionCode, resetWhenNativeVersionChanged: false)
    }

    public func autoReset(currentNativeBuildVersion: String, resetWhenNativeVersionChanged: Bool) {
        call("bundleAutoReset", [
            "nativeBuildVersion": currentNativeBuildVersion,
            "resetWhenNativeVersionChanged": resetWhenNativeVersionChanged
        ])
    }

    public func reset() {
        reset(isInternal: false)
    }

    public func reset(isInternal: Bool) {
        call("bundleReset", ["internal": isInternal])
    }

    public func setSuccess(bundle: BundleInfo, autoDeletePrevious: Bool) {
        call("bundleSetSuccess", ["id": bundle.getId(), "autoDeletePrevious": autoDeletePrevious])
    }

    public func setError(bundle: BundleInfo) {
        call("bundleSetError", ["id": bundle.getId()])
    }

    public func getBundleInfo(id: String?) -> BundleInfo {
        bundleCall("bundleGet", ["id": id]) ?? BundleInfo(id: id ?? BundleInfo.VERSION_UNKNOWN, version: "", status: .ERROR, checksum: "")
    }

    public func getBundleInfoByVersionName(version: String) -> BundleInfo? {
        bundleCall("bundleGetByName", ["version": version])
    }

    @discardableResult
    public func saveBundleInfo(id: String, bundle: BundleInfo?) -> Bool {
        call("bundleSave", ["id": id, "bundle": bundle?.toRaw()])["saved"] as? Bool ?? false
    }

    public func getCurrentBundle() -> BundleInfo {
        getBundleInfo(id: getCurrentBundleId())
    }

    public func getCurrentBundleId() -> String {
        call("bundleCurrent")["id"] as? String ?? BundleInfo.ID_BUILTIN
    }

    public func isUsingBuiltin() -> Bool {
        call("bundleCurrent")["isBuiltin"] as? Bool ?? true
    }

    public func getFallbackBundle() -> BundleInfo {
        bundleCall("bundleFallback") ?? getBundleInfo(id: BundleInfo.ID_BUILTIN)
    }

    public func getNextBundle() -> BundleInfo? {
        bundleCall("bundleNext")
    }

    public func getPreviewFallbackBundle() -> BundleInfo? {
        bundleCall("bundlePreviewFallback")
    }

    public func setPreviewFallbackBundle(fallback: String?) -> Bool {
        call("bundleSetPreviewFallback", ["id": fallback])["set"] as? Bool ?? false
    }

    public func setNextBundle(next: String?) -> Bool {
        call("bundleSetNext", ["id": next])["set"] as? Bool ?? false
    }
}
