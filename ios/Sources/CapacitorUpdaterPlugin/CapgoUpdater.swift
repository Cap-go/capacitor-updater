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

    private let versionCode: String = Bundle.main.versionCode ?? ""
    private let versionOs = UIDevice.current.systemVersion
    let libraryDir: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
    let defaultFolder: String = ""
    let bundleDirectory: String = "NoCloud/ionic_built_snapshots"
    let infoSuffix: String = "_info"
    let fallbackVersionKey: String = "pastVersion"
    let nextVersionKey: String = "nextVersion"
    var unzipPercent = 0
    let tempUnzipPrefix: String = "capgo_unzip_"

    // Add this line to declare cacheFolder
    let cacheFolder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("capgo_downloads")

    public let capServerPath: String = "serverBasePath"
    public var versionBuild: String = ""
    public var customId: String = ""
    public var pluginVersion: String = ""
    public var timeout: Double = 20
    public var statsUrl: String = ""
    public var channelUrl: String = ""
    public var defaultChannel: String = ""
    public var appId: String = ""
    public var deviceID = ""
    public var publicKey: String = ""

    // Cached key ID calculated once from publicKey
    private var cachedKeyId: String?

    // Flag to track if we received a 429 response - stops requests until app restart
    private static var rateLimitExceeded = false

    // Flag to track if we've already sent the rate limit statistic - prevents infinite loop
    private static var rateLimitStatisticSent = false

    var userAgent: String {
        let safePluginVersion = pluginVersion.isEmpty ? "unknown" : pluginVersion
        let safeAppId = appId.isEmpty ? "unknown" : appId
        return "CapacitorUpdater/\(safePluginVersion) (\(safeAppId)) ios/\(versionOs)"
    }

    lazy var alamofireSession: Session = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": self.userAgent]
        return Session(configuration: configuration)
    }()

    public var notifyDownloadRaw: (String, Int, Bool, BundleInfo?) -> Void = { _, _, _, _  in }
    public func notifyDownload(id: String, percent: Int, ignoreMultipleOfTen: Bool = false, bundle: BundleInfo? = nil) {
        notifyDownloadRaw(id, percent, ignoreMultipleOfTen, bundle)
    }
    public var notifyDownload: (String, Int) -> Void = { _, _  in }

    public func setLogger(_ logger: Logger) {
        self.logger = logger
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

    // Per-download temp file paths to prevent collisions when multiple downloads run concurrently
    func tempDataPath(for id: String) -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("package_\(id).tmp")
    }

    func updateInfoPath(for id: String) -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("update_\(id).dat")
    }

    var tempData = Data()

    // swiftlint:disable function_body_length
    public func downloadManifest(manifest: [ManifestEntry], version: String, sessionKey: String, link: String? = nil, comment: String? = nil) throws -> BundleInfo {
        let id = self.randomString(length: 10)
        logger.info("downloadManifest start \(id)")
        let destFolder = self.getBundleDirectory(id: id)
        let builtinFolder = Bundle.main.bundleURL.appendingPathComponent("public")

        // Check disk space before starting manifest download (estimate 100KB per file, minimum 50MB)
        let estimatedSize = Int64(max(manifest.count * 100 * 1024, 50 * 1024 * 1024))
        try checkDiskSpace(estimatedSize: estimatedSize)

        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true, attributes: nil)

        // Create and save BundleInfo before starting the download process
        let bundleInfo = BundleInfo(id: id, version: version, status: BundleStatus.DOWNLOADING, downloaded: Date(), checksum: "", link: link, comment: comment)
        self.saveBundleInfo(id: id, bundle: bundleInfo)

        // Send stats for manifest download start
        self.sendStats(action: "download_manifest_start", versionName: version)

        // Notify the start of the download process
        self.notifyDownload(id: id, percent: 0, ignoreMultipleOfTen: true)

        let totalFiles = manifest.count

        // Configure concurrent operation count similar to Android: min(64, max(32, totalFiles))
        manifestDownloadQueue.maxConcurrentOperationCount = min(64, max(32, totalFiles))

        // Thread-safe counters for concurrent operations
        let completedFiles = AtomicCounter()
        let hasError = AtomicBool(initialValue: false)
        var downloadError: Error?
        let errorLock = NSLock()

        // Create operations for each file
        var operations: [Operation] = []

        for entry in manifest {
            guard let fileName = entry.file_name,
                  var fileHash = entry.file_hash,
                  let downloadUrl = entry.download_url else {
                continue
            }

            // Decrypt checksum if needed (done before creating operation)
            if !self.publicKey.isEmpty && !sessionKey.isEmpty {
                do {
                    fileHash = try CryptoCipher.decryptChecksum(checksum: fileHash, publicKey: self.publicKey)
                } catch {
                    errorLock.lock()
                    downloadError = error
                    errorLock.unlock()
                    hasError.value = true
                    logger.error("Checksum decryption failed")
                    logger.debug("Bundle: \(id), File: \(fileName), Error: \(error)")
                    continue
                }
            }

            let finalFileHash = fileHash
            let fileNameWithoutPath = (fileName as NSString).lastPathComponent
            let cacheFileName = "\(finalFileHash)_\(fileNameWithoutPath)"
            let cacheFilePath = cacheFolder.appendingPathComponent(cacheFileName)

            let isBrotli = fileName.hasSuffix(".br")
            let destFileName = isBrotli ? String(fileName.dropLast(3)) : fileName
            let destFilePath = destFolder.appendingPathComponent(destFileName)
            let builtinFilePath = builtinFolder.appendingPathComponent(fileName)

            // Create parent directories synchronously (before operations start)
            try? FileManager.default.createDirectory(at: destFilePath.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)

            let operation = BlockOperation { [weak self] in
                guard let self = self else { return }
                guard !hasError.value else { return } // Skip if error already occurred

                do {
                    // Try builtin first
                    if FileManager.default.fileExists(atPath: builtinFilePath.path) && self.verifyChecksum(file: builtinFilePath, expectedHash: finalFileHash) {
                        try FileManager.default.copyItem(at: builtinFilePath, to: destFilePath)
                        self.logger.info("downloadManifest \(fileName) using builtin file \(id)")
                    }
                    // Try cache
                    else if self.tryCopyFromCache(from: cacheFilePath, to: destFilePath, expectedHash: finalFileHash) {
                        self.logger.info("downloadManifest \(fileName) copy from cache \(id)")
                    }
                    // Download
                    else {
                        let params = ManifestFileDownloadParams(
                            downloadUrl: downloadUrl,
                            destFilePath: destFilePath,
                            cacheFilePath: cacheFilePath,
                            fileHash: finalFileHash,
                            fileName: fileName,
                            destFileName: destFileName,
                            isBrotli: isBrotli,
                            sessionKey: sessionKey,
                            version: version,
                            bundleId: id
                        )
                        try self.downloadManifestFile(params: params)
                    }

                    let completed = completedFiles.increment()
                    let percent = self.calcTotalPercent(percent: Int((Double(completed) / Double(totalFiles)) * 100), min: 10, max: 70)
                    self.notifyDownload(id: id, percent: percent)

                } catch {
                    errorLock.lock()
                    if downloadError == nil {
                        downloadError = error
                    }
                    errorLock.unlock()
                    hasError.value = true
                    self.logger.error("Manifest file download failed: \(fileName)")
                    self.logger.debug("Bundle: \(id), File: \(fileName), Error: \(error.localizedDescription)")
                }
            }

            operations.append(operation)
        }

        // Execute all operations concurrently and wait for completion
        manifestDownloadQueue.addOperations(operations, waitUntilFinished: true)

        if hasError.value, let error = downloadError {
            // Update bundle status to ERROR if download failed
            let errorBundle = bundleInfo.setStatus(status: BundleStatus.ERROR.localizedString)
            self.saveBundleInfo(id: id, bundle: errorBundle)
            throw error
        }

        // Update bundle status to PENDING after successful download
        let updatedBundle = bundleInfo.setStatus(status: BundleStatus.PENDING.localizedString)
        self.saveBundleInfo(id: id, bundle: updatedBundle)

        // Send stats for manifest download complete
        self.sendStats(action: "download_manifest_complete", versionName: version)

        self.notifyDownload(id: id, percent: 100, bundle: updatedBundle)
        logger.info("downloadManifest done \(id)")
        return updatedBundle
    }
    // swiftlint:enable function_body_length

    // swiftlint:disable function_body_length
    public func download(url: URL, version: String, sessionKey: String, link: String? = nil, comment: String? = nil) throws -> BundleInfo {
        let id: String = self.randomString(length: 10)
        let semaphore = DispatchSemaphore(value: 0)
        // Each download uses its own temp files keyed by bundle ID to prevent collisions
        if version != getLocalUpdateVersion(for: id) {
            cleanDownloadData(for: id)
        }
        ensureResumableFilesExist(for: id)
        saveDownloadInfo(version, for: id)

        // Check disk space before starting download (matches Android behavior)
        try checkDiskSpace()

        var checksum = ""
        var targetSize = -1
        var lastSentProgress = 0
        var totalReceivedBytes: Int64 = loadDownloadProgress(for: id) // Retrieving the amount of already downloaded data if exist, defined at 0 otherwise
        let requestHeaders: HTTPHeaders = ["Range": "bytes=\(totalReceivedBytes)-"]

        // Send stats for zip download start
        self.sendStats(action: "download_zip_start", versionName: version)

        // Opening connection for streaming the bytes
        if totalReceivedBytes == 0 {
            self.notifyDownload(id: id, percent: 0, ignoreMultipleOfTen: true)
        }
        var mainError: NSError?
        let monitor = ClosureEventMonitor()
        monitor.requestDidCompleteTaskWithError = { (_, _, error) in
            if error != nil {
                self.logger.error("Downloading failed - ClosureEventMonitor activated")
                mainError = error as NSError?
            }
        }
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": self.userAgent]
        let session = Session(configuration: configuration, eventMonitors: [monitor])

        let request = session.streamRequest(url, headers: requestHeaders).validate().onHTTPResponse(perform: { response  in
            if let contentLength = response.headers.value(for: "Content-Length") {
                targetSize = (Int(contentLength) ?? -1) + Int(totalReceivedBytes)
            }
        }).responseStream { [weak self] streamResponse in
            guard let self = self else { return }
            switch streamResponse.event {
            case .stream(let result):
                if case .success(let data) = result {
                    self.tempData.append(data)

                    self.savePartialData(startingAt: UInt64(totalReceivedBytes), for: id) // Saving the received data in the package_<id>.tmp file
                    totalReceivedBytes += Int64(data.count)

                    let percent = max(10, Int((Double(totalReceivedBytes) / Double(targetSize)) * 70.0))

                    let currentMilestone = (percent / 10) * 10
                    if currentMilestone > lastSentProgress && currentMilestone <= 70 {
                        for milestone in stride(from: lastSentProgress + 10, through: currentMilestone, by: 10) {
                            self.notifyDownload(id: id, percent: milestone, ignoreMultipleOfTen: false)
                        }
                        lastSentProgress = currentMilestone
                    }

                } else {
                    self.logger.error("Download failed")
                }

            case .complete:
                self.logger.info("Download complete, total received bytes: \(totalReceivedBytes)")
                self.notifyDownload(id: id, percent: 70, ignoreMultipleOfTen: true)
                semaphore.signal()
            }
        }
        self.saveBundleInfo(id: id, bundle: BundleInfo(id: id, version: version, status: BundleStatus.DOWNLOADING, downloaded: Date(), checksum: checksum, link: link, comment: comment))
        let reachabilityManager = NetworkReachabilityManager()
        reachabilityManager?.startListening { status in
            switch status {
            case .notReachable:
                // Stop the download request if the network is not reachable
                request.cancel()
                mainError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
                semaphore.signal()
            default:
                break
            }
        }
        semaphore.wait()
        reachabilityManager?.stopListening()

        if mainError != nil {
            logger.error("Failed to download bundle")
            logger.debug("Error: \(String(describing: mainError))")
            self.saveBundleInfo(id: id, bundle: BundleInfo(id: id, version: version, status: BundleStatus.ERROR, downloaded: Date(), checksum: checksum, link: link, comment: comment))
            throw mainError!
        }

        let tempPath = tempDataPath(for: id)
        let finalPath = tempPath.deletingLastPathComponent().appendingPathComponent("\(id)")
        do {
            try CryptoCipher.decryptFile(filePath: tempPath, publicKey: self.publicKey, sessionKey: sessionKey, version: version)
            try FileManager.default.moveItem(at: tempPath, to: finalPath)
        } catch {
            logger.error("Failed to decrypt file")
            logger.debug("Error: \(error)")
            self.saveBundleInfo(id: id, bundle: BundleInfo(id: id, version: version, status: BundleStatus.ERROR, downloaded: Date(), checksum: checksum, link: link, comment: comment))
            cleanDownloadData(for: id)
            throw error
        }

        do {
            checksum = CryptoCipher.calcChecksum(filePath: finalPath)
            CryptoCipher.logChecksumInfo(label: "Calculated bundle checksum", hexChecksum: checksum)
            logger.info("Downloading: 80% (unzipping)")
            try self.saveDownloaded(sourceZip: finalPath, id: id, base: self.libraryDir.appendingPathComponent(self.bundleDirectory), notify: true)

        } catch {
            logger.error("Failed to unzip file")
            logger.debug("Error: \(error)")
            self.saveBundleInfo(id: id, bundle: BundleInfo(id: id, version: version, status: BundleStatus.ERROR, downloaded: Date(), checksum: checksum, link: link, comment: comment))
            // Best-effort cleanup of the decrypted zip file when unzip fails
            do {
                if FileManager.default.fileExists(atPath: finalPath.path) {
                    try FileManager.default.removeItem(at: finalPath)
                }
            } catch {
                logger.error("Could not delete failed zip")
                logger.debug("Path: \(finalPath.path), Error: \(error)")
            }
            cleanDownloadData(for: id)
            throw error
        }

        self.notifyDownload(id: id, percent: 90)
        logger.info("Downloading: 90% (wrapping up)")
        let info = BundleInfo(id: id, version: version, status: BundleStatus.PENDING, downloaded: Date(), checksum: checksum, link: link, comment: comment)
        self.saveBundleInfo(id: id, bundle: info)
        self.cleanDownloadData(for: id)

        // Send stats for zip download complete
        self.sendStats(action: "download_zip_complete", versionName: version)

        self.notifyDownload(id: id, percent: 100, bundle: info)
        logger.info("Downloading: 100% (complete)")
        return info
    }
    // swiftlint:enable function_body_length

    let operationQueue = OperationQueue()

    let manifestDownloadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.capgo.manifestDownload"
        queue.qualityOfService = .userInitiated
        return queue
    }()
}
