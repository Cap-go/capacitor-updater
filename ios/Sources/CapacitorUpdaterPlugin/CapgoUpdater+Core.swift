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

extension CapgoUpdater {
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
    public func setLogger(_ logger: Logger) {
        self.logger = logger
    }

    func createRequest(url: URL, method: String, parameters: [String: Any]? = nil, expectsJSONResponse: Bool = false) -> URLRequest? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = self.timeout
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        if expectsJSONResponse || parameters != nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        guard let parameters else {
            return request
        }

        guard JSONSerialization.isValidJSONObject(parameters) else {
            logger.error("Invalid JSON body for \(method) \(url.absoluteString)")
            return nil
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return request
        } catch {
            logger.error("Error encoding request body for \(method) \(url.absoluteString)")
            logger.debug("Error: \(error.localizedDescription)")
            return nil
        }
    }

    func performRequestImpl(_ request: URLRequest, label: String) -> RequestResult {
        let waitTimeout = max(self.timeout + 5, 10)
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var httpResponse: HTTPURLResponse?
        var requestError: Error?
        let dataRequest = self.alamofireSession.request(request).responseData(queue: self.networkResponseQueue) { response in
            responseData = response.data
            httpResponse = response.response
            requestError = response.error
            semaphore.signal()
        }
        dataRequest.resume()

        if semaphore.wait(timeout: .now() + waitTimeout) == .timedOut {
            dataRequest.cancel()
            logger.error("\(label) timed out after \(Int(waitTimeout))s")
            return RequestResult(data: responseData, response: httpResponse, error: requestError, timedOut: true)
        }

        return RequestResult(data: responseData, response: httpResponse, error: requestError, timedOut: false)
    }

    func performDownloadRequest(_ request: URLRequest, label: String) -> DownloadRequestResult {
        let waitTimeout = max(self.timeout + 5, 10)
        let semaphore = DispatchSemaphore(value: 0)
        var tempFileURL: URL?
        var httpResponse: HTTPURLResponse?
        var requestError: Error?
        let temporaryDownloadURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination: DownloadRequest.Destination = { _, _ in
            (temporaryDownloadURL, [.removePreviousFile, .createIntermediateDirectories])
        }
        let downloadRequest = self.alamofireSession.download(request, to: destination).response(queue: self.networkResponseQueue) { response in
            tempFileURL = response.fileURL
            httpResponse = response.response
            requestError = response.error
            semaphore.signal()
        }
        downloadRequest.resume()

        if semaphore.wait(timeout: .now() + waitTimeout) == .timedOut {
            downloadRequest.cancel()
            logger.error("\(label) timed out after \(Int(waitTimeout))s")
            return DownloadRequestResult(
                fileURL: existingDownloadFileURL(tempFileURL, fallback: temporaryDownloadURL),
                response: httpResponse,
                error: requestError,
                timedOut: true
            )
        }

        if isTimedOutError(requestError) {
            logger.error("\(label) timed out after \(Int(waitTimeout))s")
        }

        return DownloadRequestResult(
            fileURL: existingDownloadFileURL(tempFileURL, fallback: temporaryDownloadURL),
            response: httpResponse,
            error: requestError,
            timedOut: isTimedOutError(requestError)
        )
    }

    func existingDownloadFileURL(_ fileURL: URL?, fallback: URL) -> URL? {
        let fileManager = FileManager.default
        if let fileURL, fileManager.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        return fileManager.fileExists(atPath: fallback.path) ? fallback : nil
    }

    func storeDownloadedFile(_ downloadedFileURL: URL, at tempPath: URL, existingBytes: Int64, response: HTTPURLResponse?) throws {
        let fileManager = FileManager.default
        if existingBytes > 0 && (response?.statusCode == 206 || response == nil) {
            let resumedData = try Data(contentsOf: downloadedFileURL)
            let fileHandle = try FileHandle(forWritingTo: tempPath)
            fileHandle.seek(toFileOffset: UInt64(existingBytes))
            fileHandle.write(resumedData)
            try fileHandle.close()
            try? fileManager.removeItem(at: downloadedFileURL)
            return
        }

        if fileManager.fileExists(atPath: tempPath.path) {
            try fileManager.removeItem(at: tempPath)
        }
        try fileManager.moveItem(at: downloadedFileURL, to: tempPath)
    }

    func persistPartialDownload(_ downloadResult: DownloadRequestResult, id: String, tempPath: URL, existingBytes: Int64) {
        guard let downloadedFileURL = downloadResult.fileURL else {
            return
        }
        guard FileManager.default.fileExists(atPath: downloadedFileURL.path) else {
            return
        }
        if let statusCode = downloadResult.response?.statusCode, statusCode < 200 || statusCode >= 300 {
            return
        }

        do {
            try storeDownloadedFile(downloadedFileURL, at: tempPath, existingBytes: existingBytes, response: downloadResult.response)
            logger.info("Stored partial download for retry")
        } catch {
            logger.error("Failed to store partial download")
            logger.debug("Path: \(downloadedFileURL.path), Error: \(error)")
        }
    }
    func calcTotalPercent(percent: Int, min: Int, max: Int) -> Int {
        return (percent * (max - min)) / 100 + min
    }

    func randomString(length: Int) -> String {
        let letters: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in letters.randomElement()! })
    }

    func stableDownloadId(url: URL, version: String, sessionKey: String) -> String {
        let source = "\(sessionKey)|\(version)|\(url.absoluteString)"
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "dl-%016llx", hash)
    }

    public func setPublicKey(_ publicKey: String) {
        // Empty string means no encryption - proceed normally
        if publicKey.isEmpty {
            self.publicKey = ""
            self.cachedKeyId = nil
            return
        }

        // Non-empty: must be a valid RSA key or encrypted updates stay disabled.
        guard RSAPublicKey.load(rsaPublicKey: publicKey) != nil else {
            self.logger.error("Invalid public key in capacitor.config.json: failed to parse RSA key. Disabling encrypted updates.")
            self.publicKey = ""
            self.cachedKeyId = nil
            return
        }

        self.publicKey = publicKey
        self.cachedKeyId = CryptoCipher.calcKeyId(publicKey: publicKey)
    }

    public func getKeyId() -> String? {
        return self.cachedKeyId
    }

    var isDevEnvironment: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    func isProd() -> Bool {
        return !self.isDevEnvironment && !self.isAppStoreReceiptSandbox() && !self.hasEmbeddedMobileProvision()
    }

    /**
     * Checks if there is sufficient disk space for a download.
     * Matches Android behavior: 2x safety margin, throws "insufficient_disk_space"
     * - Parameter estimatedSize: The estimated size of the download in bytes. Defaults to 50MB.
     */
    func checkDiskSpace(estimatedSize: Int64 = 50 * 1024 * 1024) throws {
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
    func checkAndHandleRateLimitResponse(statusCode: Int?) -> Bool {
        if statusCode == 429 {
            // Send a statistic about the rate limit BEFORE setting the flag
            // Only send once to prevent infinite loop if the stat request itself gets rate limited
            if !previewSession && !CapgoUpdater.rateLimitExceeded && !CapgoUpdater.rateLimitStatisticSent {
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
    func sendRateLimitStatistic() {
        guard !statsUrl.isEmpty else {
            return
        }

        let current = getCurrentBundle()
        var parameters = createInfoObject()
        parameters.action = "rate_limit_reached"
        parameters.versionName = current.getVersionName()
        parameters.oldVersionName = ""

        // Send synchronously using semaphore (safe because we're on a background queue)
        let semaphore = DispatchSemaphore(value: 0)
        self.alamofireSession.request(
            self.statsUrl,
            method: .post,
            parameters: parameters.toParameters(),
            encoding: JSONEncoding.default,
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
}
