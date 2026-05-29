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
    // MARK: Private
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
    // Persistent path /var/mobile/Containers/Data/Application/8C0C07BE-0FD3-4FD4-B7DF-90A88E12B8C3/Library/NoCloud/ionic_built_snapshots/FOLDER
    // Hot Reload path /var/mobile/Containers/Data/Application/8C0C07BE-0FD3-4FD4-B7DF-90A88E12B8C3/Documents/FOLDER
    // Normal /private/var/containers/Bundle/Application/8C0C07BE-0FD3-4FD4-B7DF-90A88E12B8C3/App.app/public

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

    func resolveZipEntry(path: String, destUnZip: URL) throws -> URL {
        do {
            return try Self.resolvePathInsideDirectory(baseDirectory: destUnZip, relativePath: path)
        } catch SecurePathError.windowsPath {
            logger.error("Unzip failed: Windows path not supported")
            logger.debug("Invalid path: \(path)")
            self.sendStats(action: "windows_path_fail")
            throw CustomError.cannotUnzip
        } catch {
            self.sendStats(action: "canonical_path_fail")
            throw CustomError.cannotUnzip
        }
    }

    func extractZipEntry(_ archive: Archive, entry: Entry, to destPath: URL) throws {
        let fileManager = FileManager.default

        switch entry.type {
        case .directory:
            try fileManager.createDirectory(at: destPath, withIntermediateDirectories: true, attributes: nil)
        case .file:
            let parentDir = destPath.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)

            if fileManager.fileExists(atPath: destPath.path) {
                try fileManager.removeItem(at: destPath)
            }

            guard fileManager.createFile(atPath: destPath.path, contents: nil) else {
                throw CustomError.cannotUnzip
            }

            let fileHandle = try FileHandle(forWritingTo: destPath)
            defer {
                fileHandle.closeFile()
            }

            _ = try archive.extract(entry, bufferSize: 16 * 1024, skipCRC32: true) { data in
                if !data.isEmpty {
                    fileHandle.write(data)
                }
            }
        case .symlink:
            var linkData = Data()
            _ = try archive.extract(entry, bufferSize: 16 * 1024, skipCRC32: true) { data in
                linkData.append(data)
            }

            guard let linkPath = String(data: linkData, encoding: .utf8) else {
                throw CustomError.cannotUnzip
            }

            let parentDir = destPath.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)

            let isAbsolutePath = (linkPath as NSString).isAbsolutePath
            let linkURL = URL(fileURLWithPath: linkPath, relativeTo: isAbsolutePath ? nil : parentDir)
            let canonicalPath = linkURL.standardizedFileURL.path
            let canonicalDir = parentDir.standardizedFileURL.path
            let normalizedDir = canonicalDir.hasSuffix("/") ? canonicalDir : "\(canonicalDir)/"

            if canonicalPath != canonicalDir && !canonicalPath.hasPrefix(normalizedDir) {
                throw CustomError.cannotUnzip
            }

            if fileManager.fileExists(atPath: destPath.path) {
                try fileManager.removeItem(at: destPath)
            }

            try fileManager.createSymbolicLink(atPath: destPath.path, withDestinationPath: linkPath)
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
                let destPath = try resolveZipEntry(path: entry.path, destUnZip: destUnZip)

                if entry.type == .directory {
                    try FileManager.default.createDirectory(at: destPath, withIntermediateDirectories: true, attributes: nil)
                    processedEntries += 1
                    if notify && totalEntries > 0 {
                        let newPercent = self.calcTotalPercent(percent: Int(Double(processedEntries) / Double(totalEntries) * 100), min: 75, max: 81)
                        if newPercent != self.unzipPercent {
                            self.unzipPercent = newPercent
                            self.notifyDownload(id: id, percent: newPercent)
                        }
                    }
                    continue
                }

                // Create parent directories if needed
                let parentDir = destPath.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: parentDir.path) {
                    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
                }

                try self.extractZipEntry(archive, entry: entry, to: destPath)

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

    func populateDeltaCacheAsync(for id: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.populateDeltaCache(for: id)
        }
    }

    func populateDeltaCache(for id: String) {
        let bundleDir = self.getBundleDirectory(id: id)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: bundleDir.path) else {
            logger.debug("Skip delta cache population: bundle dir missing")
            return
        }

        do {
            try fileManager.createDirectory(at: cacheFolder, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.debug("Skip delta cache population: failed to create cache dir")
            return
        }

        guard let enumerator = fileManager.enumerator(at: bundleDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return
        }

        for case let fileURL as URL in enumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues?.isDirectory == true {
                continue
            }

            let checksum = CryptoCipher.calcChecksum(filePath: fileURL)
            if checksum.isEmpty {
                continue
            }

            let cacheFile = cacheFolder.appendingPathComponent("\(checksum)_\(fileURL.lastPathComponent)")
            if fileManager.fileExists(atPath: cacheFile.path) {
                continue
            }

            do {
                try fileManager.copyItem(at: fileURL, to: cacheFile)
            } catch {
                logger.debug("Delta cache copy failed: \(fileURL.path)")
            }
        }
    }

}
