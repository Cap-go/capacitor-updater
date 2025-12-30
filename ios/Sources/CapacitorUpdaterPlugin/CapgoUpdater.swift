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
    private var logger: Logger!

    private let versionCode: String = Bundle.main.versionCode ?? ""
    private let versionOs = UIDevice.current.systemVersion
    private let libraryDir: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
    private let DEFAULT_FOLDER: String = ""
    private let bundleDirectory: String = "NoCloud/ionic_built_snapshots"
    private let INFO_SUFFIX: String = "_info"
    private let FALLBACK_VERSION: String = "pastVersion"
    private let NEXT_VERSION: String = "nextVersion"
    private var unzipPercent = 0
    private let TEMP_UNZIP_PREFIX: String = "capgo_unzip_"

    // Add this line to declare cacheFolder
    private let cacheFolder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("capgo_downloads")

    public let CAP_SERVER_PATH: String = "serverBasePath"
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

    private var userAgent: String {
        let safePluginVersion = pluginVersion.isEmpty ? "unknown" : pluginVersion
        let safeAppId = appId.isEmpty ? "unknown" : appId
        return "CapacitorUpdater/\(safePluginVersion) (\(safeAppId)) ios/\(versionOs)"
    }

    private lazy var alamofireSession: Session = {
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

    private func calcTotalPercent(percent: Int, min: Int, max: Int) -> Int {
        return (percent * (max - min)) / 100 + min
    }

    private func randomString(length: Int) -> String {
        let letters: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in letters.randomElement()! })
    }

    public func setPublicKey(_ publicKey: String) {
        self.publicKey = publicKey
        if !publicKey.isEmpty {
            self.cachedKeyId = CryptoCipher.calcKeyId(publicKey: publicKey)
        } else {
            self.cachedKeyId = nil
        }
    }

    public func getKeyId() -> String? {
        return self.cachedKeyId
    }

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

    /**
     * Checks if there is sufficient disk space for a download.
     * Matches Android behavior: 2x safety margin, throws "insufficient_disk_space"
     * - Parameter estimatedSize: The estimated size of the download in bytes. Defaults to 50MB.
     */
    private func checkDiskSpace(estimatedSize: Int64 = 50 * 1024 * 1024) throws {
        let fileManager = FileManager.default
        guard let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        do {
            let attributes = try fileManager.attributesOfFileSystem(forPath: documentDirectory.path)
            guard let freeSpace = attributes[.systemFreeSize] as? Int64 else {
                logger.warn("Could not determine free disk space, proceeding with download")
                return
            }

            let requiredSpace = estimatedSize * 2 // 2x safety margin like Android

            if freeSpace < requiredSpace {
                logger.error("Insufficient disk space. Available: \(freeSpace), Required: \(requiredSpace)")
                self.sendStats(action: "insufficient_disk_space")
                throw CustomError.insufficientDiskSpace
            }
        } catch let error as CustomError {
            throw error
        } catch {
            logger.warn("Error checking disk space: \(error.localizedDescription)")
        }
    }

    /**
     * Check if a 429 (Too Many Requests) response was received and set the flag
     */
    private func checkAndHandleRateLimitResponse(statusCode: Int?) -> Bool {
        if statusCode == 429 {
            // Send a statistic about the rate limit BEFORE setting the flag
            // Only send once to prevent infinite loop if the stat request itself gets rate limited
            if !CapgoUpdater.rateLimitExceeded && !CapgoUpdater.rateLimitStatisticSent {
                CapgoUpdater.rateLimitStatisticSent = true

                // Dispatch to background queue to avoid blocking the main thread
                DispatchQueue.global(qos: .utility).async {
                    self.sendRateLimitStatistic()
                }
            }
            CapgoUpdater.rateLimitExceeded = true
            logger.warn("Rate limit exceeded (429). Stopping all stats and channel requests until app restart.")
            return true
        }
        return false
    }

    /**
     * Send a synchronous statistic about rate limiting
     * Note: This method uses a semaphore to block until the request completes.
     * It MUST be called from a background queue to avoid blocking the main thread.
     */
    private func sendRateLimitStatistic() {
        guard !statsUrl.isEmpty else {
            return
        }

        let current = getCurrentBundle()
        var parameters = createInfoObject()
        parameters.action = "rate_limit_reached"
        parameters.version_name = current.getVersionName()
        parameters.old_version_name = ""

        // Send synchronously using semaphore (safe because we're on a background queue)
        let semaphore = DispatchSemaphore(value: 0)
        self.alamofireSession.request(
            self.statsUrl,
            method: .post,
            parameters: parameters,
            encoder: JSONParameterEncoder.default,
            requestModifier: { $0.timeoutInterval = self.timeout }
        ).responseData { response in
            switch response.result {
            case .success:
                self.logger.info("Rate limit statistic sent")
            case let .failure(error):
                self.logger.error("Error sending rate limit statistic")
                self.logger.debug("Error: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    // MARK: Private
    private func hasEmbeddedMobileProvision() -> Bool {
        guard Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") == nil else {
            return true
        }
        return false
    }

    private func isAppStoreReceiptSandbox() -> Bool {

        if isEmulator() {
            return false
        } else {
            guard let url: URL = Bundle.main.appStoreReceiptURL else {
                return false
            }
            guard url.lastPathComponent == "sandboxReceipt" else {
                return false
            }
            return true
        }
    }

    private func isEmulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    // Persistent path /var/mobile/Containers/Data/Application/8C0C07BE-0FD3-4FD4-B7DF-90A88E12B8C3/Library/NoCloud/ionic_built_snapshots/FOLDER
    // Hot Reload path /var/mobile/Containers/Data/Application/8C0C07BE-0FD3-4FD4-B7DF-90A88E12B8C3/Documents/FOLDER
    // Normal /private/var/containers/Bundle/Application/8C0C07BE-0FD3-4FD4-B7DF-90A88E12B8C3/App.app/public

    private func prepareFolder(source: URL) throws {
        if !FileManager.default.fileExists(atPath: source.path) {
            do {
                try FileManager.default.createDirectory(atPath: source.path, withIntermediateDirectories: true, attributes: nil)
            } catch {
                logger.error("Cannot create directory")
                logger.debug("Directory path: \(source.path)")
                throw CustomError.cannotCreateDirectory
            }
        }
    }

    private func deleteFolder(source: URL) throws {
        do {
            try FileManager.default.removeItem(atPath: source.path)
        } catch {
            logger.error("File not removed")
            logger.debug("Path: \(source.path)")
            throw CustomError.cannotDeleteDirectory
        }
    }

    private func unflatFolder(source: URL, dest: URL) throws -> Bool {
        let index: URL = source.appendingPathComponent("index.html")
        do {
            let files: [String] = try FileManager.default.contentsOfDirectory(atPath: source.path)
            if files.count == 1 && source.appendingPathComponent(files[0]).isDirectory && !FileManager.default.fileExists(atPath: index.path) {
                try FileManager.default.moveItem(at: source.appendingPathComponent(files[0]), to: dest)
                return true
            } else {
                try FileManager.default.moveItem(at: source, to: dest)
                return false
            }
        } catch {
            logger.error("File not moved")
            logger.debug("Source: \(source.path), Dest: \(dest.path)")
            throw CustomError.cannotUnflat
        }
    }

    private func validateZipEntry(path: String, destUnZip: URL) throws {
        // Check for Windows paths
        if path.contains("\\") {
            logger.error("Unzip failed: Windows path not supported")
            logger.debug("Invalid path: \(path)")
            self.sendStats(action: "windows_path_fail")
            throw CustomError.cannotUnzip
        }

        // Check for path traversal
        let fileURL = destUnZip.appendingPathComponent(path)
        let canonicalPath = fileURL.standardizedFileURL.path
        let canonicalDir = destUnZip.standardizedFileURL.path

        if !canonicalPath.hasPrefix(canonicalDir) {
            self.sendStats(action: "canonical_path_fail")
            throw CustomError.cannotUnzip
        }
    }

    private func saveDownloaded(sourceZip: URL, id: String, base: URL, notify: Bool) throws {
        try prepareFolder(source: base)
        let destPersist: URL = base.appendingPathComponent(id)
        let destUnZip: URL = libraryDir.appendingPathComponent(TEMP_UNZIP_PREFIX + randomString(length: 10))

        self.unzipPercent = 0
        self.notifyDownload(id: id, percent: 75)

        // Open the archive
        let archive: Archive
        do {
            archive = try Archive(url: sourceZip, accessMode: .read)
        } catch {
            self.sendStats(action: "unzip_fail")
            throw CustomError.cannotUnzip
        }

        // Create destination directory
        try FileManager.default.createDirectory(at: destUnZip, withIntermediateDirectories: true, attributes: nil)

        // Count total entries for progress
        let totalEntries = archive.reduce(0) { count, _ in count + 1 }
        var processedEntries = 0

        do {
            for entry in archive {
                // Validate entry path for security
                try validateZipEntry(path: entry.path, destUnZip: destUnZip)

                let destPath = destUnZip.appendingPathComponent(entry.path)

                // Create parent directories if needed
                let parentDir = destPath.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: parentDir.path) {
                    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
                }

                // Extract the entry
                _ = try archive.extract(entry, to: destPath, skipCRC32: true)

                // Update progress
                processedEntries += 1
                if notify && totalEntries > 0 {
                    let newPercent = self.calcTotalPercent(percent: Int(Double(processedEntries) / Double(totalEntries) * 100), min: 75, max: 81)
                    if newPercent != self.unzipPercent {
                        self.unzipPercent = newPercent
                        self.notifyDownload(id: id, percent: newPercent)
                    }
                }
            }
        } catch {
            self.sendStats(action: "unzip_fail")
            try? FileManager.default.removeItem(at: destUnZip)
            throw error
        }

        if try unflatFolder(source: destUnZip, dest: destPersist) {
            try deleteFolder(source: destUnZip)
        }

        // Cleanup: remove the downloaded/decrypted zip after successful extraction
        do {
            if FileManager.default.fileExists(atPath: sourceZip.path) {
                try FileManager.default.removeItem(at: sourceZip)
            }
        } catch {
            logger.error("Could not delete source zip")
            logger.debug("Path: \(sourceZip.path), Error: \(error)")
        }
    }

    private func createInfoObject() -> InfoObject {
        return InfoObject(
            platform: "ios",
            device_id: self.deviceID,
            app_id: self.appId,
            custom_id: self.customId,
            version_build: self.versionBuild,
            version_code: self.versionCode,
            version_os: self.versionOs,
            version_name: self.getCurrentBundle().getVersionName(),
            plugin_version: self.pluginVersion,
            is_emulator: self.isEmulator(),
            is_prod: self.isProd(),
            action: nil,
            channel: nil,
            defaultChannel: self.defaultChannel,
            key_id: self.cachedKeyId
        )
    }

    public func getLatest(url: URL, channel: String?) -> AppVersion {
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        let latest: AppVersion = AppVersion()
        var parameters: InfoObject = self.createInfoObject()
        if let channel = channel {
            parameters.defaultChannel = channel
        }
        logger.info("Auto-update parameters: \(parameters)")
        let request = alamofireSession.request(url, method: .post, parameters: parameters, encoder: JSONParameterEncoder.default, requestModifier: { $0.timeoutInterval = self.timeout })

        request.validate().responseDecodable(of: AppVersionDec.self) { response in
            switch response.result {
            case .success:
                latest.statusCode = response.response?.statusCode ?? 0
                if let url = response.value?.url {
                    latest.url = url
                }
                if let checksum = response.value?.checksum {
                    latest.checksum = checksum
                }
                if let version = response.value?.version {
                    latest.version = version
                }
                if let major = response.value?.major {
                    latest.major = major
                }
                if let breaking = response.value?.breaking {
                    latest.breaking = breaking
                }
                if let error = response.value?.error {
                    latest.error = error
                }
                if let message = response.value?.message {
                    latest.message = message
                }
                if let sessionKey = response.value?.session_key {
                    latest.sessionKey = sessionKey
                }
                if let data = response.value?.data {
                    latest.data = data
                }
                if let manifest = response.value?.manifest {
                    latest.manifest = manifest
                }
                if let link = response.value?.link {
                    latest.link = link
                }
                if let comment = response.value?.comment {
                    latest.comment = comment
                }
            case let .failure(error):
                self.logger.error("Error getting latest version")
                self.logger.debug("Response: \(response.value.debugDescription), Error: \(error)")
                latest.message = "Error getting Latest"
                latest.error = "response_error"
                latest.statusCode = response.response?.statusCode ?? 0
            }
            semaphore.signal()
        }
        semaphore.wait()
        return latest
    }

    private func setCurrentBundle(bundle: String) {
        UserDefaults.standard.set(bundle, forKey: self.CAP_SERVER_PATH)
        UserDefaults.standard.synchronize()
        logger.info("Current bundle set to: \((bundle ).isEmpty ? BundleInfo.ID_BUILTIN : bundle)")
    }

    // Per-download temp file paths to prevent collisions when multiple downloads run concurrently
    private func tempDataPath(for id: String) -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("package_\(id).tmp")
    }

    private func updateInfoPath(for id: String) -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("update_\(id).dat")
    }

    private var tempData = Data()

    private func verifyChecksum(file: URL, expectedHash: String) -> Bool {
        let actualHash =    CryptoCipher.calcChecksum(filePath: file)
        return actualHash == expectedHash
    }

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
                        try self.downloadManifestFile(
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

    /// Downloads a single manifest file synchronously
    /// Used by downloadManifest for concurrent file downloads
    private func downloadManifestFile(
        downloadUrl: String,
        destFilePath: URL,
        cacheFilePath: URL,
        fileHash: String,
        fileName: String,
        destFileName: String,
        isBrotli: Bool,
        sessionKey: String,
        version: String,
        bundleId: String
    ) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var downloadError: Error?

        self.alamofireSession.download(downloadUrl).responseData { response in
            defer { semaphore.signal() }

            switch response.result {
            case .success(let data):
                do {
                    let statusCode = response.response?.statusCode ?? 200
                    if statusCode < 200 || statusCode >= 300 {
                        self.sendStats(action: "download_manifest_file_fail", versionName: "\(version):\(fileName)")
                        if let stringData = String(data: data, encoding: .utf8) {
                            throw NSError(domain: "StatusCodeError", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch. Status code (\(statusCode)) invalid. Data: \(stringData) for file \(fileName) at url \(downloadUrl)"])
                        } else {
                            throw NSError(domain: "StatusCodeError", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch. Status code (\(statusCode)) invalid for file \(fileName) at url \(downloadUrl)"])
                        }
                    }

                    // Add decryption step if public key is set and sessionKey is provided
                    var finalData = data
                    if !self.publicKey.isEmpty && !sessionKey.isEmpty {
                        let tempFile = self.cacheFolder.appendingPathComponent("temp_\(UUID().uuidString)")
                        try finalData.write(to: tempFile)
                        do {
                            try CryptoCipher.decryptFile(filePath: tempFile, publicKey: self.publicKey, sessionKey: sessionKey, version: version)
                        } catch {
                            self.sendStats(action: "decrypt_fail", versionName: version)
                            throw error
                        }
                        finalData = try Data(contentsOf: tempFile)
                        try FileManager.default.removeItem(at: tempFile)
                    }

                    // Decompress Brotli if needed
                    if isBrotli {
                        guard let decompressedData = self.decompressBrotli(data: finalData, fileName: fileName) else {
                            self.sendStats(action: "download_manifest_brotli_fail", versionName: "\(version):\(destFileName)")
                            throw NSError(domain: "BrotliDecompressionError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decompress Brotli data for file \(fileName) at url \(downloadUrl)"])
                        }
                        finalData = decompressedData
                    }

                    // Write to destination
                    try finalData.write(to: destFilePath)

                    // Verify checksum if encryption is enabled
                    if !self.publicKey.isEmpty && !sessionKey.isEmpty {
                        let calculatedChecksum = CryptoCipher.calcChecksum(filePath: destFilePath)
                        CryptoCipher.logChecksumInfo(label: "Calculated checksum", hexChecksum: calculatedChecksum)
                        CryptoCipher.logChecksumInfo(label: "Expected checksum", hexChecksum: fileHash)
                        if calculatedChecksum != fileHash {
                            try? FileManager.default.removeItem(at: destFilePath)
                            self.sendStats(action: "download_manifest_checksum_fail", versionName: "\(version):\(destFileName)")
                            throw NSError(domain: "ChecksumError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Computed checksum is not equal to required checksum (\(calculatedChecksum) != \(fileHash)) for file \(fileName) at url \(downloadUrl)"])
                        }
                    }

                    // Save to cache
                    try finalData.write(to: cacheFilePath)

                    self.logger.info("Manifest file downloaded and cached")
                    self.logger.debug("Bundle: \(bundleId), File: \(fileName), Brotli: \(isBrotli), Encrypted: \(!self.publicKey.isEmpty && !sessionKey.isEmpty)")

                } catch {
                    downloadError = error
                    self.logger.error("Manifest file download failed")
                    self.logger.debug("Bundle: \(bundleId), File: \(fileName), Error: \(error.localizedDescription)")
                }

            case .failure(let error):
                downloadError = error
                self.sendStats(action: "download_manifest_file_fail", versionName: "\(version):\(fileName)")
                self.logger.error("Manifest file download network error")
                self.logger.debug("Bundle: \(bundleId), File: \(fileName), Error: \(error.localizedDescription), Response: \(response.debugDescription)")
            }
        }

        semaphore.wait()

        if let error = downloadError {
            throw error
        }
    }

    /// Atomically try to copy a file from cache - returns true if successful, false if file doesn't exist or copy failed
    /// This handles the race condition where OS can delete cache files between exists() check and copy
    private func tryCopyFromCache(from source: URL, to destination: URL, expectedHash: String) -> Bool {
        // First quick check - if file doesn't exist, don't bother
        guard FileManager.default.fileExists(atPath: source.path) else {
            return false
        }

        // Verify checksum before copy
        guard verifyChecksum(file: source, expectedHash: expectedHash) else {
            return false
        }

        // Try to copy - if it fails (file deleted by OS between check and copy), return false
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return true
        } catch {
            // File was deleted between check and copy, or other IO error - caller should download instead
            logger.debug("Cache copy failed (likely OS eviction): \(error.localizedDescription)")
            return false
        }
    }

    private func decompressBrotli(data: Data, fileName: String) -> Data? {
        // Handle empty files
        if data.count == 0 {
            return data
        }

        // Handle the special EMPTY_BROTLI_STREAM case
        if data.count == 3 && data[0] == 0x1B && data[1] == 0x00 && data[2] == 0x06 {
            return Data()
        }

        // For small files, check if it's a minimal Brotli wrapper
        if data.count > 3 {
            let maxBytes = min(32, data.count)
            let hexDump = data.prefix(maxBytes).map { String(format: "%02x", $0) }.joined(separator: " ")
            // Handle our minimal wrapper pattern
            if data[0] == 0x1B && data[1] == 0x00 && data[2] == 0x06 && data.last == 0x03 {
                let range = data.index(data.startIndex, offsetBy: 3)..<data.index(data.endIndex, offsetBy: -1)
                return data[range]
            }

            // Handle brotli.compress minimal wrapper (quality 0)
            if data[0] == 0x0b && data[1] == 0x02 && data[2] == 0x80 && data.last == 0x03 {
                let range = data.index(data.startIndex, offsetBy: 3)..<data.index(data.endIndex, offsetBy: -1)
                return data[range]
            }
        }

        // For all other cases, try standard decompression
        let outputBufferSize = 65536
        var outputBuffer = [UInt8](repeating: 0, count: outputBufferSize)
        var decompressedData = Data()

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        var status = compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI)

        guard status != COMPRESSION_STATUS_ERROR else {
            logger.error("Failed to initialize Brotli stream")
            logger.debug("File: \(fileName), Status: \(status)")
            return nil
        }

        defer {
            compression_stream_destroy(streamPointer)
            streamPointer.deallocate()
        }

        streamPointer.pointee.src_size = 0
        streamPointer.pointee.dst_ptr = UnsafeMutablePointer<UInt8>(&outputBuffer)
        streamPointer.pointee.dst_size = outputBufferSize

        let input = data

        while true {
            if streamPointer.pointee.src_size == 0 {
                streamPointer.pointee.src_size = input.count
                input.withUnsafeBytes { rawBufferPointer in
                    if let baseAddress = rawBufferPointer.baseAddress {
                        streamPointer.pointee.src_ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
                    } else {
                        logger.error("Failed to get base address for Brotli decompression")
                        logger.debug("File: \(fileName)")
                        status = COMPRESSION_STATUS_ERROR
                        return
                    }
                }
            }

            if status == COMPRESSION_STATUS_ERROR {
                let maxBytes = min(32, data.count)
                let hexDump = data.prefix(maxBytes).map { String(format: "%02x", $0) }.joined(separator: " ")
                logger.error("Brotli decompression failed")
                logger.debug("File: \(fileName), First \(maxBytes) bytes: \(hexDump)")
                break
            }

            status = compression_stream_process(streamPointer, 0)

            let have = outputBufferSize - streamPointer.pointee.dst_size
            if have > 0 {
                decompressedData.append(outputBuffer, count: have)
            }

            if status == COMPRESSION_STATUS_END {
                break
            } else if status == COMPRESSION_STATUS_ERROR {
                logger.error("Brotli process failed")
                logger.debug("File: \(fileName), Status: \(status)")
                if let text = String(data: data, encoding: .utf8) {
                    let asciiCount = text.unicodeScalars.filter { $0.isASCII }.count
                    let totalCount = text.unicodeScalars.count
                    if totalCount > 0 && Double(asciiCount) / Double(totalCount) >= 0.8 {
                        logger.debug("Input appears to be plain text: \(text)")
                    }
                }

                let maxBytes = min(32, data.count)
                let hexDump = data.prefix(maxBytes).map { String(format: "%02x", $0) }.joined(separator: " ")
                logger.debug("Raw data: \(hexDump)")

                return nil
            }

            if streamPointer.pointee.dst_size == 0 {
                streamPointer.pointee.dst_ptr = UnsafeMutablePointer<UInt8>(&outputBuffer)
                streamPointer.pointee.dst_size = outputBufferSize
            }

            if input.count == 0 {
                logger.error("Zero input size for Brotli decompression")
                logger.debug("File: \(fileName)")
                break
            }
        }

        return status == COMPRESSION_STATUS_END ? decompressedData : nil
    }

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
    private func ensureResumableFilesExist(for id: String) {
        let fileManager = FileManager.default
        let tempPath = tempDataPath(for: id)
        let infoPath = updateInfoPath(for: id)
        if !fileManager.fileExists(atPath: tempPath.path) {
            if !fileManager.createFile(atPath: tempPath.path, contents: Data()) {
                logger.error("Cannot ensure temp data file exists")
                logger.debug("Path: \(tempPath.path)")
            }
        }

        if !fileManager.fileExists(atPath: infoPath.path) {
            if !fileManager.createFile(atPath: infoPath.path, contents: Data()) {
                logger.error("Cannot ensure update info file exists")
                logger.debug("Path: \(infoPath.path)")
            }
        }
    }

    private func cleanDownloadData(for id: String) {
        let fileManager = FileManager.default
        let tempPath = tempDataPath(for: id)
        let infoPath = updateInfoPath(for: id)
        // Deleting package_<id>.tmp
        if fileManager.fileExists(atPath: tempPath.path) {
            do {
                try fileManager.removeItem(at: tempPath)
            } catch {
                logger.error("Could not delete temp data file")
                logger.debug("Path: \(tempPath), Error: \(error)")
            }
        }
        // Deleting update_<id>.dat
        if fileManager.fileExists(atPath: infoPath.path) {
            do {
                try fileManager.removeItem(at: infoPath)
            } catch {
                logger.error("Could not delete update info file")
                logger.debug("Path: \(infoPath), Error: \(error)")
            }
        }
    }

    private func savePartialData(startingAt byteOffset: UInt64, for id: String) {
        let fileManager = FileManager.default
        let tempPath = tempDataPath(for: id)
        do {
            // Check if package_<id>.tmp exist
            if !fileManager.fileExists(atPath: tempPath.path) {
                try self.tempData.write(to: tempPath, options: .atomicWrite)
            } else {
                // If yes, it start writing on it
                let fileHandle = try FileHandle(forWritingTo: tempPath)
                fileHandle.seek(toFileOffset: byteOffset) // Moving at the specified position to start writing
                fileHandle.write(self.tempData)
                fileHandle.closeFile()
            }
        } catch {
            logger.error("Failed to write partial data")
            logger.debug("Byte offset: \(byteOffset), Error: \(error)")
        }
        self.tempData.removeAll() // Clearing tempData to avoid writing the same data multiple times
    }

    private func saveDownloadInfo(_ version: String, for id: String) {
        let infoPath = updateInfoPath(for: id)
        do {
            try "\(version)".write(to: infoPath, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to save download progress")
            logger.debug("Error: \(error)")
        }
    }

    private func getLocalUpdateVersion(for id: String) -> String { // Return the version that was tried to be downloaded on last download attempt
        let infoPath = updateInfoPath(for: id)
        if !FileManager.default.fileExists(atPath: infoPath.path) {
            return "nil"
        }
        guard let versionString = try? String(contentsOf: infoPath),
              let version = Optional(versionString) else {
            return "nil"
        }
        return version
    }

    private func loadDownloadProgress(for id: String) -> Int64 {
        let fileManager = FileManager.default
        let tempPath = tempDataPath(for: id)
        do {
            let attributes = try fileManager.attributesOfItem(atPath: tempPath.path)
            if let fileSize = attributes[.size] as? NSNumber {
                return fileSize.int64Value
            }
        } catch {
            logger.error("Could not retrieve download progress size")
            logger.debug("Error: \(error)")
        }
        return 0
    }

    public func list(raw: Bool = false) -> [BundleInfo] {
        if !raw {
            // UserDefaults.standard.dictionaryRepresentation().values
            let dest: URL = libraryDir.appendingPathComponent(bundleDirectory)
            do {
                let files: [String] = try FileManager.default.contentsOfDirectory(atPath: dest.path)
                var res: [BundleInfo] = []
                logger.info("list File : \(dest.path)")
                if dest.exist {
                    for id: String in files {
                        res.append(self.getBundleInfo(id: id))
                    }
                }
                return res
            } catch {
                logger.info("No version available \(dest.path)")
                return []
            }
        } else {
            guard let regex = try? NSRegularExpression(pattern: "^[0-9A-Za-z]{10}_info$") else {
                logger.error("Invalid regex ?????")
                return []
            }
            return UserDefaults.standard.dictionaryRepresentation().keys.filter {
                let range = NSRange($0.startIndex..., in: $0)
                let matches = regex.matches(in: $0, range: range)
                return !matches.isEmpty
            }.map {
                $0.components(separatedBy: "_")[0]
            }.map {
                self.getBundleInfo(id: $0)
            }
        }

    }

    public func delete(id: String, removeInfo: Bool) -> Bool {
        let deleted: BundleInfo = self.getBundleInfo(id: id)
        if deleted.isBuiltin() || self.getCurrentBundleId() == id {
            logger.info("Cannot delete current or builtin bundle")
            logger.debug("Bundle ID: \(id)")
            return false
        }

        // Check if this is the next bundle and prevent deletion if it is
        if let next = self.getNextBundle(),
           !next.isDeleted() &&
            !next.isErrorStatus() &&
            next.getId() == id {
            logger.info("Cannot delete the next bundle")
            logger.debug("Bundle ID: \(id)")
            return false
        }

        let destPersist: URL = libraryDir.appendingPathComponent(bundleDirectory).appendingPathComponent(id)
        do {
            try FileManager.default.removeItem(atPath: destPersist.path)
        } catch {
            logger.error("Bundle folder not removed")
            logger.debug("Path: \(destPersist.path)")
            // even if, we don;t care. Android doesn't care
            if removeInfo {
                self.removeBundleInfo(id: id)
            }
            self.sendStats(action: "delete", versionName: deleted.getVersionName())
            return false
        }
        if removeInfo {
            self.removeBundleInfo(id: id)
        } else {
            self.saveBundleInfo(id: id, bundle: deleted.setStatus(status: BundleStatus.DELETED.localizedString))
        }
        logger.info("Bundle deleted successfully")
        logger.debug("Version: \(deleted.getVersionName())")
        self.sendStats(action: "delete", versionName: deleted.getVersionName())
        return true
    }

    public func delete(id: String) -> Bool {
        return self.delete(id: id, removeInfo: true)
    }

    public func cleanupDeltaCache() {
        cleanupDeltaCache(threadToCheck: nil)
    }

    public func cleanupDeltaCache(threadToCheck: Thread?) {
        // Check if thread was cancelled
        if let thread = threadToCheck, thread.isCancelled {
            logger.warn("cleanupDeltaCache was cancelled before starting")
            return
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cacheFolder.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: cacheFolder)
            logger.info("Cleaned up delta cache folder")
        } catch {
            logger.error("Failed to cleanup delta cache")
            logger.debug("Error: \(error.localizedDescription)")
        }
    }

    public func cleanupDownloadDirectories(allowedIds: Set<String>) {
        cleanupDownloadDirectories(allowedIds: allowedIds, threadToCheck: nil)
    }

    public func cleanupDownloadDirectories(allowedIds: Set<String>, threadToCheck: Thread?) {
        let bundleRoot = libraryDir.appendingPathComponent(bundleDirectory)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: bundleRoot.path) else {
            return
        }

        do {
            let contents = try fileManager.contentsOfDirectory(at: bundleRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])

            for url in contents {
                // Check if thread was cancelled
                if let thread = threadToCheck, thread.isCancelled {
                    logger.warn("cleanupDownloadDirectories was cancelled")
                    return
                }

                let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
                if resourceValues.isDirectory != true {
                    continue
                }

                let id = url.lastPathComponent

                if allowedIds.contains(id) {
                    continue
                }

                do {
                    try fileManager.removeItem(at: url)
                    self.removeBundleInfo(id: id)
                    logger.info("Deleted orphan bundle directory")
                    logger.debug("Bundle ID: \(id)")
                } catch {
                    logger.error("Failed to delete orphan bundle directory")
                    logger.debug("Bundle ID: \(id), Error: \(error.localizedDescription)")
                }
            }
        } catch {
            logger.error("Failed to enumerate bundle directory for cleanup")
            logger.debug("Error: \(error.localizedDescription)")
        }
    }

    public func cleanupOrphanedTempFolders(threadToCheck: Thread?) {
        let fileManager = FileManager.default

        do {
            let contents = try fileManager.contentsOfDirectory(at: libraryDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])

            for url in contents {
                // Check if thread was cancelled
                if let thread = threadToCheck, thread.isCancelled {
                    logger.warn("cleanupOrphanedTempFolders was cancelled")
                    return
                }

                let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
                if resourceValues.isDirectory != true {
                    continue
                }

                let folderName = url.lastPathComponent

                // Only delete folders with the temp unzip prefix
                if !folderName.hasPrefix(TEMP_UNZIP_PREFIX) {
                    continue
                }

                do {
                    try fileManager.removeItem(at: url)
                    logger.info("Deleted orphaned temp unzip folder")
                    logger.debug("Folder: \(folderName)")
                } catch {
                    logger.error("Failed to delete orphaned temp folder")
                    logger.debug("Folder: \(folderName), Error: \(error.localizedDescription)")
                }
            }
        } catch {
            logger.error("Failed to enumerate library directory for temp folder cleanup")
            logger.debug("Error: \(error.localizedDescription)")
        }

        // Also cleanup old download temp files (package_*.tmp and update_*.dat)
        cleanupOldDownloadTempFiles()
    }

    private func cleanupOldDownloadTempFiles() {
        let fileManager = FileManager.default
        guard let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        do {
            let contents = try fileManager.contentsOfDirectory(at: documentsDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            let oneHourAgo = Date().addingTimeInterval(-3600)

            for url in contents {
                let fileName = url.lastPathComponent
                // Only cleanup package_*.tmp and update_*.dat files
                let isDownloadTemp = (fileName.hasPrefix("package_") && fileName.hasSuffix(".tmp")) ||
                                     (fileName.hasPrefix("update_") && fileName.hasSuffix(".dat"))
                if !isDownloadTemp {
                    continue
                }

                // Only delete files older than 1 hour
                if let modDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modDate < oneHourAgo {
                    do {
                        try fileManager.removeItem(at: url)
                        logger.debug("Deleted old download temp file: \(fileName)")
                    } catch {
                        logger.debug("Failed to delete old download temp file: \(fileName), Error: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            logger.debug("Failed to enumerate documents directory for temp file cleanup: \(error.localizedDescription)")
        }
    }

    public func getBundleDirectory(id: String) -> URL {
        return libraryDir.appendingPathComponent(self.bundleDirectory).appendingPathComponent(id)
    }

    public func set(bundle: BundleInfo) -> Bool {
        return self.set(id: bundle.getId())
    }

    private func bundleExists(id: String) -> Bool {
        let destPersist: URL = self.getBundleDirectory(id: id)
        let indexPersist: URL = destPersist.appendingPathComponent("index.html")
        let bundleIndo: BundleInfo = self.getBundleInfo(id: id)
        if
            destPersist.exist &&
                destPersist.isDirectory &&
                !indexPersist.isDirectory &&
                indexPersist.exist &&
                !bundleIndo.isDeleted() {
            return true
        }
        return false
    }

    public func set(id: String) -> Bool {
        let newBundle: BundleInfo = self.getBundleInfo(id: id)
        if newBundle.isBuiltin() {
            self.reset()
            return true
        }
        if bundleExists(id: id) {
            let currentBundleName = self.getCurrentBundle().getVersionName()
            self.setCurrentBundle(bundle: self.getBundleDirectory(id: id).path)
            self.setBundleStatus(id: id, status: BundleStatus.PENDING)
            self.sendStats(action: "set", versionName: newBundle.getVersionName(), oldVersionName: currentBundleName)
            return true
        }
        self.setBundleStatus(id: id, status: BundleStatus.ERROR)
        self.sendStats(action: "set_fail", versionName: newBundle.getVersionName())
        return false
    }

    public func autoReset() {
        let currentBundle: BundleInfo = self.getCurrentBundle()
        if !currentBundle.isBuiltin() && !self.bundleExists(id: currentBundle.getId()) {
            logger.info("Folder at bundle path does not exist. Triggering reset.")
            self.reset()
        }
    }

    public func reset() {
        self.reset(isInternal: false)
    }

    public func reset(isInternal: Bool) {
        logger.info("reset: \(isInternal)")
        let currentBundleName = self.getCurrentBundle().getVersionName()
        self.setCurrentBundle(bundle: "")
        self.setFallbackBundle(fallback: Optional<BundleInfo>.none)
        _ = self.setNextBundle(next: Optional<String>.none)
        if !isInternal {
            self.sendStats(action: "reset", versionName: self.getCurrentBundle().getVersionName(), oldVersionName: currentBundleName)
        }
    }

    public func setSuccess(bundle: BundleInfo, autoDeletePrevious: Bool) {
        self.setBundleStatus(id: bundle.getId(), status: BundleStatus.SUCCESS)
        let fallback: BundleInfo = self.getFallbackBundle()
        logger.info("Fallback bundle is: \(fallback.toString())")
        logger.info("Version successfully loaded: \(bundle.toString())")
        if autoDeletePrevious && !fallback.isBuiltin() && fallback.getId() != bundle.getId() {
            let res = self.delete(id: fallback.getId())
            if res {
                logger.info("Deleted previous bundle")
                logger.debug("Bundle: \(fallback.toString())")
            } else {
                logger.error("Failed to delete previous bundle")
                logger.debug("Bundle: \(fallback.toString())")
            }
        }
        self.setFallbackBundle(fallback: bundle)
    }

    public func setError(bundle: BundleInfo) {
        self.setBundleStatus(id: bundle.getId(), status: BundleStatus.ERROR)
    }

    func unsetChannel(defaultChannelKey: String, configDefaultChannel: String) -> SetChannel {
        let setChannel: SetChannel = SetChannel()

        // Clear persisted defaultChannel and revert to config value
        UserDefaults.standard.removeObject(forKey: defaultChannelKey)
        UserDefaults.standard.synchronize()
        self.defaultChannel = configDefaultChannel
        self.logger.info("Persisted defaultChannel cleared, reverted to config value: \(configDefaultChannel)")

        setChannel.status = "ok"
        setChannel.message = "Channel override removed"
        return setChannel
    }

    func setChannel(channel: String, defaultChannelKey: String, allowSetDefaultChannel: Bool) -> SetChannel {
        let setChannel: SetChannel = SetChannel()

        // Check if setting defaultChannel is allowed
        if !allowSetDefaultChannel {
            logger.error("setChannel is disabled by allowSetDefaultChannel config")
            setChannel.message = "setChannel is disabled by configuration"
            setChannel.error = "disabled_by_config"
            return setChannel
        }

        // Check if rate limit was exceeded
        if CapgoUpdater.rateLimitExceeded {
            logger.debug("Skipping setChannel due to rate limit (429). Requests will resume after app restart.")
            setChannel.message = "Rate limit exceeded"
            setChannel.error = "rate_limit_exceeded"
            return setChannel
        }

        if (self.channelUrl ).isEmpty {
            logger.error("Channel URL is not set")
            setChannel.message = "Channel URL is not set"
            setChannel.error = "missing_config"
            return setChannel
        }
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        var parameters: InfoObject = self.createInfoObject()
        parameters.channel = channel

        let request = alamofireSession.request(self.channelUrl, method: .post, parameters: parameters, encoder: JSONParameterEncoder.default, requestModifier: { $0.timeoutInterval = self.timeout })

        request.validate().responseDecodable(of: SetChannelDec.self) { response in
            // Check for 429 rate limit
            if self.checkAndHandleRateLimitResponse(statusCode: response.response?.statusCode) {
                setChannel.message = "Rate limit exceeded"
                setChannel.error = "rate_limit_exceeded"
                semaphore.signal()
                return
            }

            switch response.result {
            case .success:
                if let responseValue = response.value {
                    if let error = responseValue.error {
                        setChannel.error = error
                    } else {
                        // Success - persist defaultChannel
                        self.defaultChannel = channel
                        UserDefaults.standard.set(channel, forKey: defaultChannelKey)
                        UserDefaults.standard.synchronize()
                        self.logger.info("defaultChannel persisted locally: \(channel)")

                        setChannel.status = responseValue.status ?? ""
                        setChannel.message = responseValue.message ?? ""
                    }
                }
            case let .failure(error):
                self.logger.error("Error setting channel")
                self.logger.debug("Error: \(error)")
                setChannel.error = "Request failed: \(error.localizedDescription)"
            }
            semaphore.signal()
        }
        semaphore.wait()
        return setChannel
    }

    func getChannel() -> GetChannel {
        let getChannel: GetChannel = GetChannel()

        // Check if rate limit was exceeded
        if CapgoUpdater.rateLimitExceeded {
            logger.debug("Skipping getChannel due to rate limit (429). Requests will resume after app restart.")
            getChannel.message = "Rate limit exceeded"
            getChannel.error = "rate_limit_exceeded"
            return getChannel
        }

        if (self.channelUrl ).isEmpty {
            logger.error("Channel URL is not set")
            getChannel.message = "Channel URL is not set"
            getChannel.error = "missing_config"
            return getChannel
        }
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        let parameters: InfoObject = self.createInfoObject()
        let request = alamofireSession.request(self.channelUrl, method: .put, parameters: parameters, encoder: JSONParameterEncoder.default, requestModifier: { $0.timeoutInterval = self.timeout })

        request.validate().responseDecodable(of: GetChannelDec.self) { response in
            defer {
                semaphore.signal()
            }

            // Check for 429 rate limit
            if self.checkAndHandleRateLimitResponse(statusCode: response.response?.statusCode) {
                getChannel.message = "Rate limit exceeded"
                getChannel.error = "rate_limit_exceeded"
                return
            }

            switch response.result {
            case .success:
                if let responseValue = response.value {
                    if let error = responseValue.error {
                        getChannel.error = error
                    } else {
                        getChannel.status = responseValue.status ?? ""
                        getChannel.message = responseValue.message ?? ""
                        getChannel.channel = responseValue.channel ?? ""
                        getChannel.allowSet = responseValue.allowSet ?? true
                    }
                }
            case let .failure(error):
                if let data = response.data, let bodyString = String(data: data, encoding: .utf8) {
                    if bodyString.contains("channel_not_found") && response.response?.statusCode == 400 && !self.defaultChannel.isEmpty {
                        getChannel.channel = self.defaultChannel
                        getChannel.status = "default"
                        return
                    }
                }

                self.logger.error("Error getting channel")
                self.logger.debug("Error: \(error)")
                getChannel.error = "Request failed: \(error.localizedDescription)"
            }
        }
        semaphore.wait()
        return getChannel
    }

    func listChannels() -> ListChannels {
        let listChannels: ListChannels = ListChannels()

        // Check if rate limit was exceeded
        if CapgoUpdater.rateLimitExceeded {
            logger.debug("Skipping listChannels due to rate limit (429). Requests will resume after app restart.")
            listChannels.error = "rate_limit_exceeded"
            return listChannels
        }

        if (self.channelUrl).isEmpty {
            logger.error("Channel URL is not set")
            listChannels.error = "Channel URL is not set"
            return listChannels
        }

        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)

        // Create info object and convert to query parameters
        let infoObject = self.createInfoObject()

        // Create query parameters from InfoObject
        var urlComponents = URLComponents(string: self.channelUrl)
        var queryItems: [URLQueryItem] = []

        // Convert InfoObject to dictionary using Mirror
        let mirror = Mirror(reflecting: infoObject)
        for child in mirror.children {
            if let key = child.label, let value = child.value as? CustomStringConvertible {
                queryItems.append(URLQueryItem(name: key, value: String(describing: value)))
            } else if let key = child.label {
                // Handle optional values
                let mirror = Mirror(reflecting: child.value)
                if let value = mirror.children.first?.value {
                    queryItems.append(URLQueryItem(name: key, value: String(describing: value)))
                }
            }
        }

        urlComponents?.queryItems = queryItems

        guard let url = urlComponents?.url else {
            logger.error("Invalid channel URL")
            listChannels.error = "Invalid channel URL"
            return listChannels
        }

        let request = alamofireSession.request(url, method: .get, requestModifier: { $0.timeoutInterval = self.timeout })

        request.validate().responseDecodable(of: ListChannelsDec.self) { response in
            defer {
                semaphore.signal()
            }

            // Check for 429 rate limit
            if self.checkAndHandleRateLimitResponse(statusCode: response.response?.statusCode) {
                listChannels.error = "rate_limit_exceeded"
                return
            }

            switch response.result {
            case .success:
                if let responseValue = response.value {
                    // Check for server-side errors
                    if let error = responseValue.error {
                        listChannels.error = error
                        return
                    }

                    // Backend returns direct array, so channels should be populated by our custom decoder
                    if let channels = responseValue.channels {
                        listChannels.channels = channels.map { channel in
                            var channelDict: [String: Any] = [:]
                            channelDict["id"] = channel.id ?? ""
                            channelDict["name"] = channel.name ?? ""
                            channelDict["public"] = channel.public ?? false
                            channelDict["allow_self_set"] = channel.allow_self_set ?? false
                            return channelDict
                        }
                    }
                }
            case let .failure(error):
                self.logger.error("Error listing channels")
                self.logger.debug("Error: \(error)")
                listChannels.error = "Request failed: \(error.localizedDescription)"
            }
        }
        semaphore.wait()
        return listChannels
    }

    private let operationQueue = OperationQueue()

    private let manifestDownloadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.capgo.manifestDownload"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func sendStats(action: String, versionName: String? = nil, oldVersionName: String? = "") {
        // Check if rate limit was exceeded
        if CapgoUpdater.rateLimitExceeded {
            logger.debug("Skipping sendStats due to rate limit (429). Stats will resume after app restart.")
            return
        }

        guard !statsUrl.isEmpty else {
            return
        }
        operationQueue.maxConcurrentOperationCount = 1

        let versionName = versionName ?? getCurrentBundle().getVersionName()

        var parameters = createInfoObject()
        parameters.action = action
        parameters.version_name = versionName
        parameters.old_version_name = oldVersionName ?? ""

        let operation = BlockOperation {
            let semaphore = DispatchSemaphore(value: 0)
            self.alamofireSession.request(
                self.statsUrl,
                method: .post,
                parameters: parameters,
                encoder: JSONParameterEncoder.default,
                requestModifier: { $0.timeoutInterval = self.timeout }
            ).responseData { response in
                // Check for 429 rate limit
                if self.checkAndHandleRateLimitResponse(statusCode: response.response?.statusCode) {
                    semaphore.signal()
                    return
                }

                switch response.result {
                case .success:
                    self.logger.info("Stats sent successfully")
                    self.logger.debug("Action: \(action), Version: \(versionName)")
                case let .failure(error):
                    self.logger.error("Error sending stats")
                    self.logger.debug("Response: \(response.value?.debugDescription ?? "nil"), Error: \(error.localizedDescription)")
                }
                semaphore.signal()
            }
            semaphore.wait()
        }
        operationQueue.addOperation(operation)

    }

    public func getBundleInfo(id: String?) -> BundleInfo {
        var trueId = BundleInfo.VERSION_UNKNOWN
        if id != nil {
            trueId = id!
        }
        let result: BundleInfo
        if BundleInfo.ID_BUILTIN == trueId {
            result = BundleInfo(id: trueId, version: "", status: BundleStatus.SUCCESS, checksum: "")
        } else if BundleInfo.VERSION_UNKNOWN == trueId {
            result = BundleInfo(id: trueId, version: "", status: BundleStatus.ERROR, checksum: "")
        } else {
            do {
                result = try UserDefaults.standard.getObj(forKey: "\(trueId)\(self.INFO_SUFFIX)", castTo: BundleInfo.self)
            } catch {
                logger.error("Failed to parse bundle info")
                logger.debug("Bundle ID: \(trueId), Error: \(error.localizedDescription)")
                result = BundleInfo(id: trueId, version: "", status: BundleStatus.PENDING, checksum: "")
            }
        }
        return result
    }

    public func getBundleInfoByVersionName(version: String) -> BundleInfo? {
        let installed: [BundleInfo] = self.list()
        for i in installed {
            if i.getVersionName() == version {
                return i
            }
        }
        return nil
    }

    private func removeBundleInfo(id: String) {
        self.saveBundleInfo(id: id, bundle: nil)
    }

    public func saveBundleInfo(id: String, bundle: BundleInfo?) {
        if bundle != nil && (bundle!.isBuiltin() || bundle!.isUnknown()) {
            logger.info("Not saving info for bundle [\(id)] \(bundle?.toString() ?? "")")
            return
        }
        if bundle == nil {
            logger.info("Removing info for bundle [\(id)]")
            UserDefaults.standard.removeObject(forKey: "\(id)\(self.INFO_SUFFIX)")
        } else {
            let update = bundle!.setId(id: id)
            logger.info("Storing info for bundle [\(id)] \(update.toString())")
            do {
                try UserDefaults.standard.setObj(update, forKey: "\(id)\(self.INFO_SUFFIX)")
            } catch {
                logger.error("Failed to save bundle info")
                logger.debug("Bundle ID: \(id), Error: \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.synchronize()
    }

    private func setBundleStatus(id: String, status: BundleStatus) {
        logger.info("Setting status for bundle [\(id)] to \(status)")
        let info = self.getBundleInfo(id: id)
        self.saveBundleInfo(id: id, bundle: info.setStatus(status: status.localizedString))
    }

    public func getCurrentBundle() -> BundleInfo {
        return self.getBundleInfo(id: self.getCurrentBundleId())
    }

    public func getCurrentBundleId() -> String {
        guard let bundlePath: String = UserDefaults.standard.string(forKey: self.CAP_SERVER_PATH) else {
            return BundleInfo.ID_BUILTIN
        }
        if (bundlePath).isEmpty {
            return BundleInfo.ID_BUILTIN
        }
        let bundleID: String = bundlePath.components(separatedBy: "/").last ?? bundlePath
        return bundleID
    }

    public func isUsingBuiltin() -> Bool {
        return (UserDefaults.standard.string(forKey: self.CAP_SERVER_PATH) ?? "") == self.DEFAULT_FOLDER
    }

    public func getFallbackBundle() -> BundleInfo {
        let id: String = UserDefaults.standard.string(forKey: self.FALLBACK_VERSION) ?? BundleInfo.ID_BUILTIN
        return self.getBundleInfo(id: id)
    }

    private func setFallbackBundle(fallback: BundleInfo?) {
        UserDefaults.standard.set(fallback == nil ? BundleInfo.ID_BUILTIN : fallback!.getId(), forKey: self.FALLBACK_VERSION)
        UserDefaults.standard.synchronize()
    }

    public func getNextBundle() -> BundleInfo? {
        let id: String? = UserDefaults.standard.string(forKey: self.NEXT_VERSION)
        return self.getBundleInfo(id: id)
    }

    public func setNextBundle(next: String?) -> Bool {
        guard let nextId: String = next else {
            UserDefaults.standard.removeObject(forKey: self.NEXT_VERSION)
            UserDefaults.standard.synchronize()
            return false
        }
        let newBundle: BundleInfo = self.getBundleInfo(id: nextId)
        if !newBundle.isBuiltin() && !self.bundleExists(id: nextId) {
            return false
        }
        UserDefaults.standard.set(nextId, forKey: self.NEXT_VERSION)
        UserDefaults.standard.synchronize()
        self.setBundleStatus(id: nextId, status: BundleStatus.PENDING)
        return true
    }
}
