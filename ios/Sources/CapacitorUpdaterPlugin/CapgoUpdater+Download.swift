/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Alamofire

/// Parameters for downloading a single manifest file
struct ManifestFileDownloadParams {
    let downloadUrl: String
    let destFilePath: URL
    let cacheFilePath: URL
    let fileHash: String
    let fileName: String
    let destFileName: String
    let isBrotli: Bool
    let sessionKey: String
    let version: String
    let bundleId: String
}

// MARK: - Download Operations
extension CapgoUpdater {
    /// Downloads a single manifest file synchronously
    /// Used by downloadManifest for concurrent file downloads
    func downloadManifestFile(params: ManifestFileDownloadParams) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var downloadError: Error?

        self.alamofireSession.download(params.downloadUrl).responseData { response in
            defer { semaphore.signal() }

            switch response.result {
            case .success(let data):
                do {
                    try self.processManifestFileData(data: data, params: params, response: response)
                } catch {
                    downloadError = error
                    self.logger.error("Manifest file download failed")
                    self.logger.debug("Bundle: \(params.bundleId), File: \(params.fileName), Error: \(error.localizedDescription)")
                }

            case .failure(let error):
                downloadError = error
                self.sendStats(action: "download_manifest_file_fail", versionName: "\(params.version):\(params.fileName)")
                self.logger.error("Manifest file download network error")
                self.logger.debug("Bundle: \(params.bundleId), File: \(params.fileName), Error: \(error.localizedDescription)")
            }
        }

        semaphore.wait()

        if let error = downloadError {
            throw error
        }
    }

    /// Process downloaded manifest file data - handles decryption, decompression and verification
    private func processManifestFileData(
        data: Data,
        params: ManifestFileDownloadParams,
        response: AFDownloadResponse<Data>
    ) throws {
        let statusCode = response.response?.statusCode ?? 200
        if statusCode < 200 || statusCode >= 300 {
            sendStats(action: "download_manifest_file_fail", versionName: "\(params.version):\(params.fileName)")
            if let stringData = String(data: data, encoding: .utf8) {
                throw NSError(
                    domain: "StatusCodeError",
                    code: statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to fetch. Status code (\(statusCode)) invalid. Data: \(stringData) for file \(params.fileName) at url \(params.downloadUrl)"]
                )
            } else {
                throw NSError(
                    domain: "StatusCodeError",
                    code: statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to fetch. Status code (\(statusCode)) invalid for file \(params.fileName) at url \(params.downloadUrl)"]
                )
            }
        }

        // Add decryption step if public key is set and sessionKey is provided
        var finalData = data
        if !self.publicKey.isEmpty && !params.sessionKey.isEmpty {
            finalData = try decryptManifestData(data: data, params: params)
        }

        // Decompress Brotli if needed
        if params.isBrotli {
            guard let decompressedData = self.decompressBrotli(data: finalData, fileName: params.fileName) else {
                self.sendStats(action: "download_manifest_brotli_fail", versionName: "\(params.version):\(params.destFileName)")
                throw NSError(
                    domain: "BrotliDecompressionError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to decompress Brotli data for file \(params.fileName) at url \(params.downloadUrl)"]
                )
            }
            finalData = decompressedData
        }

        // Write to destination
        try finalData.write(to: params.destFilePath)

        // Verify checksum if encryption is enabled
        if !self.publicKey.isEmpty && !params.sessionKey.isEmpty {
            try verifyManifestChecksum(params: params)
        }

        // Save to cache
        try finalData.write(to: params.cacheFilePath)

        logger.info("Manifest file downloaded and cached")
        logger.debug("Bundle: \(params.bundleId), File: \(params.fileName), Brotli: \(params.isBrotli), Encrypted: \(!self.publicKey.isEmpty && !params.sessionKey.isEmpty)")
    }

    /// Decrypt manifest data using the public key and session key
    private func decryptManifestData(data: Data, params: ManifestFileDownloadParams) throws -> Data {
        let tempFile = self.cacheFolder.appendingPathComponent("temp_\(UUID().uuidString)")
        try data.write(to: tempFile)
        do {
            try CryptoCipher.decryptFile(filePath: tempFile, publicKey: self.publicKey, sessionKey: params.sessionKey, version: params.version)
        } catch {
            self.sendStats(action: "decrypt_fail", versionName: params.version)
            throw error
        }
        let finalData = try Data(contentsOf: tempFile)
        try FileManager.default.removeItem(at: tempFile)
        return finalData
    }

    /// Verify checksum of downloaded manifest file
    private func verifyManifestChecksum(params: ManifestFileDownloadParams) throws {
        let calculatedChecksum = CryptoCipher.calcChecksum(filePath: params.destFilePath)
        CryptoCipher.logChecksumInfo(label: "Calculated checksum", hexChecksum: calculatedChecksum)
        CryptoCipher.logChecksumInfo(label: "Expected checksum", hexChecksum: params.fileHash)
        if calculatedChecksum != params.fileHash {
            try? FileManager.default.removeItem(at: params.destFilePath)
            self.sendStats(action: "download_manifest_checksum_fail", versionName: "\(params.version):\(params.destFileName)")
            throw NSError(
                domain: "ChecksumError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Computed checksum is not equal to required checksum (\(calculatedChecksum) != \(params.fileHash)) for file \(params.fileName) at url \(params.downloadUrl)"]
            )
        }
    }

    /// Setup and execute the zip download stream
    func executeZipDownload(
        url: URL,
        bundleId: String,
        version: String,
        totalReceivedBytes: inout Int64,
        semaphore: DispatchSemaphore
    ) -> (Session, DataStreamRequest, NSError?) {
        var lastSentProgress = 0
        var targetSize = -1
        var mainError: NSError?

        let requestHeaders: HTTPHeaders = ["Range": "bytes=\(totalReceivedBytes)-"]

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

        // Capture initial value for closure
        let initialReceivedBytes = totalReceivedBytes

        let request = session.streamRequest(url, headers: requestHeaders).validate().onHTTPResponse { response in
            if let contentLength = response.headers.value(for: "Content-Length") {
                targetSize = (Int(contentLength) ?? -1) + Int(initialReceivedBytes)
            }
        }.responseStream { [weak self] streamResponse in
            guard let self = self else { return }
            switch streamResponse.event {
            case .stream(let result):
                if case .success(let data) = result {
                    self.tempData.append(data)
                    self.savePartialData(startingAt: UInt64(totalReceivedBytes), for: bundleId)
                    totalReceivedBytes += Int64(data.count)

                    let percent = max(10, Int((Double(totalReceivedBytes) / Double(targetSize)) * 70.0))
                    let currentMilestone = (percent / 10) * 10
                    if currentMilestone > lastSentProgress && currentMilestone <= 70 {
                        for milestone in stride(from: lastSentProgress + 10, through: currentMilestone, by: 10) {
                            self.notifyDownload(id: bundleId, percent: milestone, ignoreMultipleOfTen: false)
                        }
                        lastSentProgress = currentMilestone
                    }
                } else {
                    self.logger.error("Download failed")
                }
            case .complete:
                self.logger.info("Download complete, total received bytes: \(totalReceivedBytes)")
                self.notifyDownload(id: bundleId, percent: 70, ignoreMultipleOfTen: true)
                semaphore.signal()
            }
        }

        return (session, request, mainError)
    }

    /// Process downloaded zip file - decrypt and unzip
    func processDownloadedZip(
        bundleId: String,
        version: String,
        sessionKey: String,
        checksum: inout String,
        link: String?,
        comment: String?
    ) throws -> BundleInfo {
        let tempPath = tempDataPath(for: bundleId)
        let finalPath = tempPath.deletingLastPathComponent().appendingPathComponent("\(bundleId)")

        do {
            try CryptoCipher.decryptFile(filePath: tempPath, publicKey: self.publicKey, sessionKey: sessionKey, version: version)
            try FileManager.default.moveItem(at: tempPath, to: finalPath)
        } catch {
            logger.error("Failed to decrypt file")
            logger.debug("Error: \(error)")
            saveBundleInfo(
                id: bundleId,
                bundle: BundleInfo(id: bundleId, version: version, status: BundleStatus.ERROR, downloaded: Date(), checksum: checksum, link: link, comment: comment)
            )
            cleanDownloadData(for: bundleId)
            throw error
        }

        do {
            checksum = CryptoCipher.calcChecksum(filePath: finalPath)
            CryptoCipher.logChecksumInfo(label: "Calculated bundle checksum", hexChecksum: checksum)
            logger.info("Downloading: 80% (unzipping)")
            try saveDownloaded(sourceZip: finalPath, id: bundleId, base: libraryDir.appendingPathComponent(bundleDirectory), notify: true)
        } catch {
            logger.error("Failed to unzip file")
            logger.debug("Error: \(error)")
            saveBundleInfo(
                id: bundleId,
                bundle: BundleInfo(id: bundleId, version: version, status: BundleStatus.ERROR, downloaded: Date(), checksum: checksum, link: link, comment: comment)
            )
            // Best-effort cleanup of the decrypted zip file when unzip fails
            do {
                if FileManager.default.fileExists(atPath: finalPath.path) {
                    try FileManager.default.removeItem(at: finalPath)
                }
            } catch {
                logger.error("Could not delete failed zip")
                logger.debug("Path: \(finalPath.path), Error: \(error)")
            }
            cleanDownloadData(for: bundleId)
            throw error
        }

        notifyDownload(id: bundleId, percent: 90)
        logger.info("Downloading: 90% (wrapping up)")
        let info = BundleInfo(id: bundleId, version: version, status: BundleStatus.PENDING, downloaded: Date(), checksum: checksum, link: link, comment: comment)
        saveBundleInfo(id: bundleId, bundle: info)
        cleanDownloadData(for: bundleId)

        // Send stats for zip download complete
        sendStats(action: "download_zip_complete", versionName: version)

        notifyDownload(id: bundleId, percent: 100, bundle: info)
        logger.info("Downloading: 100% (complete)")
        return info
    }

    // MARK: - Download Resume Helpers

    func ensureResumableFilesExist(for id: String) {
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

    func cleanDownloadData(for id: String) {
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

    func savePartialData(startingAt byteOffset: UInt64, for id: String) {
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

    func saveDownloadInfo(_ version: String, for id: String) {
        let infoPath = updateInfoPath(for: id)
        do {
            try "\(version)".write(to: infoPath, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to save download progress")
            logger.debug("Error: \(error)")
        }
    }

    func getLocalUpdateVersion(for id: String) -> String {
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

    func loadDownloadProgress(for id: String) -> Int64 {
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
}
