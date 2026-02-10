/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import ZIPFoundation
import Compression

// MARK: - File Operations
extension CapgoUpdater {
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

    func hasEmbeddedMobileProvision() -> Bool {
        guard Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") == nil else {
            return true
        }
        return false
    }

    func isAppStoreReceiptSandbox() -> Bool {
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

    func isEmulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    func prepareFolder(source: URL) throws {
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

    func deleteFolder(source: URL) throws {
        do {
            try FileManager.default.removeItem(atPath: source.path)
        } catch {
            logger.error("File not removed")
            logger.debug("Path: \(source.path)")
            throw CustomError.cannotDeleteDirectory
        }
    }

    func unflatFolder(source: URL, dest: URL) throws -> Bool {
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

    func validateZipEntry(path: String, destUnZip: URL) throws {
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

    func saveDownloaded(sourceZip: URL, id: String, base: URL, notify: Bool) throws {
        try prepareFolder(source: base)
        let destPersist: URL = base.appendingPathComponent(id)
        let destUnZip: URL = libraryDir.appendingPathComponent(tempUnzipPrefix + randomString(length: 10))

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

    func calcTotalPercent(percent: Int, min: Int, max: Int) -> Int {
        return (percent * (max - min)) / 100 + min
    }

    func randomString(length: Int) -> String {
        let letters: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in letters.randomElement()! })
    }

    func verifyChecksum(file: URL, expectedHash: String) -> Bool {
        let actualHash = CryptoCipher.calcChecksum(filePath: file)
        return actualHash == expectedHash
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

    // swiftlint:disable function_body_length cyclomatic_complexity
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
    // swiftlint:enable function_body_length cyclomatic_complexity
}
