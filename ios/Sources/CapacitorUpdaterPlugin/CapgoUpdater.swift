/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import ZIPFoundation
import Alamofire
import Compression
import UIKit

@objc public class CapgoUpdater: NSObject {
    var logger: Logger!

    let versionCode: String = Bundle.main.versionCode ?? ""
    let versionOs = UIDevice.current.systemVersion
    let libraryDir: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
    let defaultFolder: String = ""
    let bundleDirectory: String = "NoCloud/ionic_built_snapshots"
    let infoSuffix: String = "_info"
    let fallbackVersionKey: String = "pastVersion"
    let nextVersionKey: String = "nextVersion"
    let previewFallbackVersionKey: String = "previewFallbackVersion"
    var unzipPercent = 0
    let tempUnzipPrefix: String = "capgo_unzip_"

    // Add this line to declare cacheFolder
    let cacheFolder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("capgo_downloads")

    public let capServerPathKey: String = "serverBasePath"
    public var versionBuild: String = ""
    public var customId: String = ""
    public var pluginVersion: String = ""
    public var timeout: Double = 20
    public var statsUrl: String = ""
    public var channelUrl: String = ""
    public var defaultChannel: String = ""
    public var appId: String = ""
    public var deviceID = ""
    public var previewSession = false
    public var publicKey: String = ""

    // Cached key ID calculated once from publicKey
    var cachedKeyId: String?

    // Flag to track if we received a 429 response - stops requests until app restart
    static var rateLimitExceeded = false

    // Flag to track if we've already sent the rate limit statistic - prevents infinite loop
    static var rateLimitStatisticSent = false

    // Stats batching - queue events and send max once per second
    var statsQueue: [StatsEvent] = []
    let statsQueueLock = NSLock()
    var statsFlushTimer: Timer?
    static let statsFlushInterval: TimeInterval = 1.0

    static func sanitizeHeaderValue(_ value: String) -> String {
        if value.isEmpty {
            return "unknown"
        }

        let filteredScalars = value.unicodeScalars.filter { scalar in
            let cp = scalar.value
            let isVisibleAscii = (0x20...0x7E).contains(cp)
            let isIso88591 = (0xA0...0xFF).contains(cp)
            return isVisibleAscii || isIso88591
        }

        let sanitized = String(String.UnicodeScalarView(filteredScalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "unknown" : sanitized
    }

    static func buildUserAgent(appId: String, pluginVersion: String, versionOs: String) -> String {
        let safePluginVersion = sanitizeHeaderValue(pluginVersion)
        let safeAppId = sanitizeHeaderValue(appId)
        let safeVersionOs = sanitizeHeaderValue(versionOs)
        return "CapacitorUpdater/\(safePluginVersion) (\(safeAppId)) ios/\(safeVersionOs)"
    }

    var userAgent: String {
        CapgoUpdater.buildUserAgent(appId: appId, pluginVersion: pluginVersion, versionOs: versionOs)
    }

    struct RequestResult {
        let data: Data?
        let response: HTTPURLResponse?
        let error: Error?
        let timedOut: Bool
    }

    struct DownloadRequestResult {
        let fileURL: URL?
        let response: HTTPURLResponse?
        let error: Error?
        let timedOut: Bool
    }

    enum SecurePathError: Error {
        case emptyPath
        case windowsPath
        case absolutePath
        case pathTraversal
    }

    static func resolvePathInsideDirectory(baseDirectory: URL, relativePath: String) throws -> URL {
        if relativePath.isEmpty {
            throw SecurePathError.emptyPath
        }
        if relativePath.contains("\\") || relativePath.contains("\0") {
            throw SecurePathError.windowsPath
        }
        if (relativePath as NSString).isAbsolutePath {
            throw SecurePathError.absolutePath
        }

        let canonicalBase = baseDirectory.standardizedFileURL
        let canonicalBasePath = canonicalBase.path
        let normalizedBasePath = canonicalBasePath.hasSuffix("/") ? canonicalBasePath : "\(canonicalBasePath)/"
        let canonicalTarget = canonicalBase.appendingPathComponent(relativePath).standardizedFileURL
        let canonicalTargetPath = canonicalTarget.path

        if canonicalTargetPath != canonicalBasePath && !canonicalTargetPath.hasPrefix(normalizedBasePath) {
            throw SecurePathError.pathTraversal
        }

        return canonicalTarget
    }

    static func resolveManifestTargetPath(baseDirectory: URL, fileName: String) throws -> URL {
        let isBrotli = fileName.hasSuffix(".br")
        let targetFileName = isBrotli ? String(fileName.dropLast(3)) : fileName
        return try resolvePathInsideDirectory(baseDirectory: baseDirectory, relativePath: targetFileName)
    }

    func isTimedOutError(_ error: Error?) -> Bool {
        guard let nsError = error as NSError? else {
            return false
        }

        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    lazy var alamofireSession: Session = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": self.userAgent]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return Session(configuration: configuration)
    }()
    let networkResponseQueue = DispatchQueue(label: "ee.forgr.capacitor-updater.network-response", qos: .utility)

    public var notifyDownloadRaw: (String, Int, Bool, BundleInfo?) -> Void = { _, _, _, _  in }
    public var notifyDownload: (String, Int) -> Void = { _, _  in }
    public var notifyListeners: (String, [String: Any]) -> Void = { _, _ in }
    var tempData = Data()
    let operationQueue = OperationQueue()
    let manifestDownloadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ee.forgr.capacitor-updater.manifest-download"
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    func performRequest(_ request: URLRequest, label: String) -> RequestResult {
        performRequestImpl(request, label: label)
    }

    public func getLatest(url: URL, channel: String?, appIdOverride: String? = nil) -> AppVersion {
        getLatestImpl(url: url, channel: channel, appIdOverride: appIdOverride)
    }

    public func download(url: URL, version: String, sessionKey: String, link: String? = nil, comment: String? = nil) throws -> BundleInfo {
        try downloadImpl(url: url, version: version, sessionKey: sessionKey, link: link, comment: comment)
    }

    func sendStats(action: String, versionName: String? = nil, oldVersionName: String? = "") {
        sendStatsWithMetadata(action: action, versionName: versionName, oldVersionName: oldVersionName, metadata: nil)
    }

    func sendStats(action: String, versionName: String?, oldVersionName: String?, metadata: [String: String]) {
        sendStatsWithMetadata(action: action, versionName: versionName, oldVersionName: oldVersionName, metadata: metadata)
    }

    public func getBundleInfo(id: String?) -> BundleInfo {
        getBundleInfoImpl(id: id)
    }

    public func getBundleInfoByVersionName(version: String) -> BundleInfo? {
        getBundleInfoByVersionNameImpl(version: version)
    }

    public func saveBundleInfo(id: String, bundle: BundleInfo?) {
        saveBundleInfoImpl(id: id, bundle: bundle)
    }

    public func getCurrentBundle() -> BundleInfo {
        getCurrentBundleImpl()
    }

    public func getFallbackBundle() -> BundleInfo {
        getFallbackBundleImpl()
    }

    public func getNextBundle() -> BundleInfo? {
        getNextBundleImpl()
    }

    public func setNextBundle(next: String?) -> Bool {
        setNextBundleImpl(next: next)
    }

    func captureResetState() -> ResetState {
        captureResetStateImpl()
    }

    func restoreResetState(_ state: ResetState) {
        restoreResetStateImpl(state)
    }

    func prepareResetStateForTransition() {
        prepareResetStateForTransitionImpl()
    }

    func finalizeResetTransition(previousBundleName: String, isInternal: Bool) {
        finalizeResetTransitionImpl(previousBundleName: previousBundleName, isInternal: isInternal)
    }

    func canSet(bundle: BundleInfo) -> Bool {
        canSetImpl(bundle: bundle)
    }

    public func set(bundle: BundleInfo) -> Bool {
        setImpl(bundle: bundle)
    }

    func stagePendingReload(bundle: BundleInfo) -> Bool {
        stagePendingReloadImpl(bundle: bundle)
    }

    func finalizePendingReload(bundle: BundleInfo, previousBundleName: String) {
        finalizePendingReloadImpl(bundle: bundle, previousBundleName: previousBundleName)
    }

    public func reset(isInternal: Bool) {
        resetImpl(isInternal: isInternal)
    }

    deinit {
        // Invalidate the stats timer to prevent memory leaks
        statsFlushTimer?.invalidate()
        statsFlushTimer = nil

        // Flush any remaining stats before deallocation
        flushStatsQueue()
    }
}
