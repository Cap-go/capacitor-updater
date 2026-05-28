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
    struct ZipDownloadContext {
        let id: String
        let url: URL
        let version: String
        let checksum: String
        let tempPath: URL
        let totalReceivedBytes: Int64
        let link: String?
        let comment: String?
    }

    /// Atomically try to copy a file from cache - returns true if successful, false if file doesn't exist or copy failed
    /// This handles the race condition where OS can delete cache files between exists() check and copy
    func tryCopyFromCache(from source: URL, to destination: URL, expectedHash: String) -> Bool {
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

    func decompressBrotli(data: Data, fileName: String) -> Data? {
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

    func downloadImpl(url: URL, version: String, sessionKey: String, link: String? = nil, comment: String? = nil) throws -> BundleInfo {
        let id: String = self.randomString(length: 10)
        // Each download uses its own temp files keyed by bundle ID to prevent collisions
        if version != getLocalUpdateVersion(for: id) {
            cleanDownloadData(for: id)
        }
        ensureResumableFilesExist(for: id)
        saveDownloadInfo(version, for: id)

        // Check disk space before starting download (matches Android behavior)
        try checkDiskSpace()

        var checksum = ""
        let totalReceivedBytes: Int64 = loadDownloadProgress(for: id) // Retrieving the amount of already downloaded data if exist, defined at 0 otherwise
        let tempPath = tempDataPath(for: id)
        let bundleInfo = BundleInfo(id: id, version: version, status: BundleStatus.DOWNLOADING, downloaded: Date(), checksum: checksum, link: link, comment: comment)
        self.saveBundleInfo(id: id, bundle: bundleInfo)

        // Send stats for zip download start
        self.sendStats(action: "download_zip_start", versionName: version)

        // Opening connection for streaming the bytes
        if totalReceivedBytes == 0 {
            self.notifyDownload(id: id, percent: 0, ignoreMultipleOfTen: true)
        }
        try performZipDownload(context: ZipDownloadContext(
            id: id,
            url: url,
            version: version,
            checksum: checksum,
            tempPath: tempPath,
            totalReceivedBytes: totalReceivedBytes,
            link: link,
            comment: comment
        ))

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
            self.populateDeltaCacheAsync(for: id)

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

    func performZipDownload(context: ZipDownloadContext) throws {
        guard var request = createRequest(url: context.url, method: "GET") else {
            self.saveBundleInfo(id: context.id, bundle: errorBundle(context: context))
            throw NSError(
                domain: "DownloadError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid download request for \(context.url.absoluteString)"]
            )
        }

        if context.totalReceivedBytes > 0 {
            request.setValue("bytes=\(context.totalReceivedBytes)-", forHTTPHeaderField: "Range")
        }

        let downloadResult = performDownloadRequest(request, label: "download \(context.version)")
        if let error = zipDownloadError(downloadResult, context: context) {
            logger.error("Failed to download bundle")
            logger.debug("Error: \(error)")
            self.saveBundleInfo(id: context.id, bundle: errorBundle(context: context))
            throw error
        }

        guard let downloadedFileURL = downloadResult.fileURL else {
            self.saveBundleInfo(id: context.id, bundle: errorBundle(context: context))
            throw NSError(
                domain: "DownloadError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Downloaded file is missing at \(context.tempPath.path)"]
            )
        }

        do {
            try storeDownloadedFile(
                downloadedFileURL,
                at: context.tempPath,
                existingBytes: context.totalReceivedBytes,
                response: downloadResult.response
            )
            self.notifyDownload(id: context.id, percent: 70, ignoreMultipleOfTen: true)
            self.logger.info("Download complete")
        } catch {
            self.saveBundleInfo(id: context.id, bundle: errorBundle(context: context))
            throw error
        }
    }

    func zipDownloadError(_ downloadResult: DownloadRequestResult, context: ZipDownloadContext) -> NSError? {
        if downloadResult.timedOut {
            persistPartialDownload(
                downloadResult,
                id: context.id,
                tempPath: context.tempPath,
                existingBytes: context.totalReceivedBytes
            )
            return NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: "Timed out downloading bundle from \(context.url.absoluteString)"]
            )
        }

        if let error = downloadResult.error {
            logger.error("Download failed")
            persistPartialDownload(
                downloadResult,
                id: context.id,
                tempPath: context.tempPath,
                existingBytes: context.totalReceivedBytes
            )
            return error as NSError
        }

        if let statusCode = downloadResult.response?.statusCode, statusCode < 200 || statusCode >= 300 {
            logger.error("Download failed")
            return NSError(
                domain: "DownloadError",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Download request failed with status code \(statusCode)"]
            )
        }

        return nil
    }

    func errorBundle(context: ZipDownloadContext) -> BundleInfo {
        return BundleInfo(
            id: context.id,
            version: context.version,
            status: BundleStatus.ERROR,
            downloaded: Date(),
            checksum: context.checksum,
            link: context.link,
            comment: context.comment
        )
    }
}
