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
    final class ManifestDownloadTracker {
        let completedFiles = AtomicCounter()
        let hasError = AtomicBool(initialValue: false)
        let errorLock = NSLock()
        var downloadError: Error?

        func record(error: Error) {
            errorLock.lock()
            if downloadError == nil {
                downloadError = error
            }
            errorLock.unlock()
            hasError.value = true
        }
    }

    struct ManifestDownloadContext {
        let id: String
        let version: String
        let sessionKey: String
        let destFolder: URL
        let builtinFolder: URL
        let totalFiles: Int
    }

    struct ManifestFileDownloadContext {
        let downloadUrl: String
        let destFilePath: URL
        let builtinFilePath: URL
        let cacheFilePath: URL
        let legacyCacheFilePath: URL?
        let fileHash: String
        let fileName: String
        let destFileName: String
        let isBrotli: Bool
        let sessionKey: String
        let version: String
        let bundleId: String
    }

    public func downloadManifest(
        manifest: [ManifestEntry],
        version: String,
        sessionKey: String,
        link: String? = nil,
        comment: String? = nil
    ) throws -> BundleInfo {
        let id = self.randomString(length: 10)
        logger.info("downloadManifest start \(id)")
        let destFolder = self.getBundleDirectory(id: id)
        let builtinFolder = Bundle.main.bundleURL.appendingPathComponent("public")

        let estimatedSize = Int64(max(manifest.count * 100 * 1024, 50 * 1024 * 1024))
        try checkDiskSpace(estimatedSize: estimatedSize)
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true, attributes: nil)

        let bundleInfo = BundleInfo(
            id: id,
            version: version,
            status: BundleStatus.DOWNLOADING,
            downloaded: Date(),
            checksum: "",
            link: link,
            comment: comment
        )
        self.saveBundleInfo(id: id, bundle: bundleInfo)
        self.sendStats(action: "download_manifest_start", versionName: version)
        self.notifyDownload(id: id, percent: 0, ignoreMultipleOfTen: true)

        manifestDownloadQueue.maxConcurrentOperationCount = min(8, max(1, manifest.count))
        let tracker = ManifestDownloadTracker()
        let context = ManifestDownloadContext(
            id: id,
            version: version,
            sessionKey: sessionKey,
            destFolder: destFolder,
            builtinFolder: builtinFolder,
            totalFiles: manifest.count
        )
        let operations = manifest.compactMap {
            makeManifestOperation(entry: $0, context: context, tracker: tracker)
        }
        manifestDownloadQueue.addOperations(operations, waitUntilFinished: true)

        if tracker.hasError.value {
            let resolvedError = tracker.downloadError ?? NSError(
                domain: "ManifestDownloadError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Manifest download failed due to invalid or missing entries"]
            )
            self.saveBundleInfo(id: id, bundle: bundleInfo.setStatus(status: BundleStatus.ERROR.storedValue))
            throw resolvedError
        }

        let updatedBundle = bundleInfo.setStatus(status: BundleStatus.PENDING.storedValue)
        self.saveBundleInfo(id: id, bundle: updatedBundle)
        self.sendStats(action: "download_manifest_complete", versionName: version)
        self.notifyDownload(id: id, percent: 100, bundle: updatedBundle)
        logger.info("downloadManifest done \(id)")
        return updatedBundle
    }

    func makeManifestOperation(
        entry: ManifestEntry,
        context: ManifestDownloadContext,
        tracker: ManifestDownloadTracker
    ) -> Operation? {
        guard let fileContext = makeManifestFileContext(entry: entry, context: context, tracker: tracker) else {
            return nil
        }

        return BlockOperation { [weak self] in
            guard let self = self, !tracker.hasError.value else { return }

            do {
                try self.installManifestFile(context: fileContext)
                let completed = tracker.completedFiles.increment()
                let percent = self.calcTotalPercent(
                    percent: Int((Double(completed) / Double(context.totalFiles)) * 100),
                    min: 10,
                    max: 70
                )
                self.notifyDownload(id: context.id, percent: percent)
            } catch {
                tracker.record(error: error)
                self.logger.error("Manifest file download failed: \(fileContext.fileName)")
                self.logger.debug("Bundle: \(context.id), File: \(fileContext.fileName), Error: \(error.localizedDescription)")
            }
        }
    }

    func makeManifestFileContext(
        entry: ManifestEntry,
        context: ManifestDownloadContext,
        tracker: ManifestDownloadTracker
    ) -> ManifestFileDownloadContext? {
        guard let fileName = entry.fileName, let downloadUrl = entry.downloadUrl else {
            tracker.record(error: manifestEntryError(code: 1, message: "Manifest entry is missing file_name or download_url"))
            logger.error("Manifest entry is missing file_name or download_url")
            return nil
        }

        guard let entryFileHash = entry.fileHash, !entryFileHash.isEmpty else {
            let message = "Manifest entry is missing file_hash for \(entry.fileName ?? "unknown")"
            tracker.record(error: manifestEntryError(code: 2, message: message))
            logger.error("Missing file_hash for manifest entry: \(entry.fileName ?? "unknown")")
            return nil
        }

        guard let fileHash = decryptManifestChecksum(entryFileHash, fileName: fileName, context: context, tracker: tracker) else {
            return nil
        }

        do {
            return try resolvedManifestFileContext(
                fileName: fileName,
                downloadUrl: downloadUrl,
                fileHash: fileHash,
                context: context
            )
        } catch {
            logger.error("Invalid manifest file path: \(fileName)")
            self.sendStats(action: "manifest_path_fail", versionName: "\(context.version):\(fileName)")
            tracker.record(error: error)
            return nil
        }
    }

    func manifestEntryError(code: Int, message: String) -> NSError {
        return NSError(
            domain: "ManifestEntryError",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    func decryptManifestChecksum(
        _ fileHash: String,
        fileName: String,
        context: ManifestDownloadContext,
        tracker: ManifestDownloadTracker
    ) -> String? {
        guard !self.publicKey.isEmpty, !context.sessionKey.isEmpty else {
            return fileHash
        }

        do {
            return try CryptoCipher.decryptChecksum(checksum: fileHash, publicKey: self.publicKey)
        } catch {
            tracker.record(error: error)
            logger.error("Checksum decryption failed")
            logger.debug("Bundle: \(context.id), File: \(fileName), Error: \(error)")
            return nil
        }
    }

    func resolvedManifestFileContext(
        fileName: String,
        downloadUrl: String,
        fileHash: String,
        context: ManifestDownloadContext
    ) throws -> ManifestFileDownloadContext {
        let fileNameWithoutPath = (fileName as NSString).lastPathComponent
        let isBrotli = fileName.hasSuffix(".br")
        let cacheBaseName = isBrotli ? String(fileNameWithoutPath.dropLast(3)) : fileNameWithoutPath
        let cacheFilePath = cacheFolder.appendingPathComponent("\(fileHash)_\(cacheBaseName)")
        let legacyCacheFilePath = isBrotli ? cacheFolder.appendingPathComponent("\(fileHash)_\(fileNameWithoutPath)") : nil
        let destFileName = isBrotli ? String(fileName.dropLast(3)) : fileName
        let destFilePath = try Self.resolveManifestTargetPath(baseDirectory: context.destFolder, fileName: fileName)
        let builtinFilePath = try Self.resolvePathInsideDirectory(baseDirectory: context.builtinFolder, relativePath: fileName)
        try? FileManager.default.createDirectory(at: destFilePath.deletingLastPathComponent(), withIntermediateDirectories: true)

        return ManifestFileDownloadContext(
            downloadUrl: downloadUrl,
            destFilePath: destFilePath,
            builtinFilePath: builtinFilePath,
            cacheFilePath: cacheFilePath,
            legacyCacheFilePath: legacyCacheFilePath,
            fileHash: fileHash,
            fileName: fileName,
            destFileName: destFileName,
            isBrotli: isBrotli,
            sessionKey: context.sessionKey,
            version: context.version,
            bundleId: context.id
        )
    }

    func installManifestFile(context: ManifestFileDownloadContext) throws {
        if FileManager.default.fileExists(atPath: context.builtinFilePath.path) &&
            self.verifyChecksum(file: context.builtinFilePath, expectedHash: context.fileHash) {
            try FileManager.default.copyItem(at: context.builtinFilePath, to: context.destFilePath)
            self.logger.info("downloadManifest \(context.fileName) using builtin file \(context.bundleId)")
            return
        }

        if self.tryCopyFromCache(from: context.cacheFilePath, to: context.destFilePath, expectedHash: context.fileHash) {
            self.logger.info("downloadManifest \(context.fileName) copy from cache \(context.bundleId)")
            return
        }

        if let legacyCacheFilePath = context.legacyCacheFilePath,
           self.tryCopyFromCache(from: legacyCacheFilePath, to: context.destFilePath, expectedHash: context.fileHash) {
            self.logger.info("downloadManifest \(context.fileName) copy from cache \(context.bundleId)")
            return
        }

        try self.downloadManifestFile(context)
    }

    func downloadManifestFile(_ context: ManifestFileDownloadContext) throws {
        guard let url = URL(string: context.downloadUrl) else {
            throw NSError(
                domain: "ManifestDownloadError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid manifest download URL for file \(context.fileName): \(context.downloadUrl)"]
            )
        }

        guard let request = createRequest(url: url, method: "GET") else {
            throw NSError(
                domain: "ManifestDownloadError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid manifest request for file \(context.fileName): \(context.downloadUrl)"]
            )
        }

        let result = performRequest(request, label: "downloadManifestFile \(context.fileName)")
        let data = try manifestResponseData(result, context: context)

        do {
            let finalData = try preparedManifestData(data, context: context)
            try finalData.write(to: context.destFilePath)
            try verifyManifestChecksum(context: context)
            try finalData.write(to: context.cacheFilePath)
            self.logger.info("Manifest file downloaded and cached")
            self.logger.debug(
                "Bundle: \(context.bundleId), File: \(context.fileName), Brotli: \(context.isBrotli), Encrypted: \(!self.publicKey.isEmpty && !context.sessionKey.isEmpty)"
            )
        } catch {
            self.logger.error("Manifest file download failed")
            self.logger.debug("Bundle: \(context.bundleId), File: \(context.fileName), Error: \(error.localizedDescription)")
            throw error
        }
    }

    func manifestResponseData(_ result: RequestResult, context: ManifestFileDownloadContext) throws -> Data {
        if result.timedOut {
            self.sendStats(action: "download_manifest_file_fail", versionName: "\(context.version):\(context.fileName)")
            throw NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut,
                userInfo: [
                    NSLocalizedDescriptionKey: "Timed out downloading manifest file \(context.fileName) at url \(context.downloadUrl)"
                ]
            )
        }

        if let error = result.error {
            self.sendStats(action: "download_manifest_file_fail", versionName: "\(context.version):\(context.fileName)")
            self.logger.error("Manifest file download network error")
            self.logger.debug("Bundle: \(context.bundleId), File: \(context.fileName), Error: \(error.localizedDescription)")
            throw error
        }

        guard let data = result.data else {
            self.sendStats(action: "download_manifest_file_fail", versionName: "\(context.version):\(context.fileName)")
            throw NSError(
                domain: "ManifestDownloadError",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Manifest file response was empty for \(context.fileName) at url \(context.downloadUrl)"]
            )
        }

        try validateManifestResponseStatus(result.response?.statusCode ?? 200, data: data, context: context)
        return data
    }

    func validateManifestResponseStatus(_ statusCode: Int, data: Data, context: ManifestFileDownloadContext) throws {
        guard statusCode < 200 || statusCode >= 300 else {
            return
        }

        self.sendStats(action: "download_manifest_file_fail", versionName: "\(context.version):\(context.fileName)")
        let message: String
        if let stringData = String(data: data, encoding: .utf8) {
            message = "Failed to fetch. Status code (\(statusCode)) invalid. Data: \(stringData) for file \(context.fileName) at url \(context.downloadUrl)"
        } else {
            message = "Failed to fetch. Status code (\(statusCode)) invalid for file \(context.fileName) at url \(context.downloadUrl)"
        }
        throw NSError(domain: "StatusCodeError", code: statusCode, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func preparedManifestData(_ data: Data, context: ManifestFileDownloadContext) throws -> Data {
        var finalData = try decryptManifestFileData(data, context: context)
        if context.isBrotli {
            guard let decompressedData = self.decompressBrotli(data: finalData, fileName: context.fileName) else {
                self.sendStats(action: "download_manifest_brotli_fail", versionName: "\(context.version):\(context.destFileName)")
                throw NSError(
                    domain: "BrotliDecompressionError",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Failed to decompress Brotli data for file \(context.fileName) at url \(context.downloadUrl)"
                    ]
                )
            }
            finalData = decompressedData
        }
        return finalData
    }

    func decryptManifestFileData(_ data: Data, context: ManifestFileDownloadContext) throws -> Data {
        guard !self.publicKey.isEmpty, !context.sessionKey.isEmpty else {
            return data
        }

        let tempFile = self.cacheFolder.appendingPathComponent("temp_\(UUID().uuidString)")
        try data.write(to: tempFile)
        do {
            try CryptoCipher.decryptFile(
                filePath: tempFile,
                publicKey: self.publicKey,
                sessionKey: context.sessionKey,
                version: context.version
            )
            let finalData = try Data(contentsOf: tempFile)
            try FileManager.default.removeItem(at: tempFile)
            return finalData
        } catch {
            self.sendStats(action: "decrypt_fail", versionName: context.version)
            throw error
        }
    }

    func verifyManifestChecksum(context: ManifestFileDownloadContext) throws {
        let calculatedChecksum = CryptoCipher.calcChecksum(filePath: context.destFilePath)
        CryptoCipher.logChecksumInfo(label: "Calculated checksum", hexChecksum: calculatedChecksum)
        CryptoCipher.logChecksumInfo(label: "Expected checksum", hexChecksum: context.fileHash)
        guard calculatedChecksum == context.fileHash else {
            try? FileManager.default.removeItem(at: context.destFilePath)
            self.sendStats(action: "download_manifest_checksum_fail", versionName: "\(context.version):\(context.destFileName)")
            let message = "Computed checksum is not equal to required checksum (\(calculatedChecksum) != \(context.fileHash)) for file \(context.fileName) at url \(context.downloadUrl)"
            throw NSError(domain: "ChecksumError", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
