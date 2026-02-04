/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation

// MARK: - Cleanup Operations
extension CapgoUpdater {
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
            let contents = try fileManager.contentsOfDirectory(
                at: bundleRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

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

                let bundleId = url.lastPathComponent

                if allowedIds.contains(bundleId) {
                    continue
                }

                do {
                    try fileManager.removeItem(at: url)
                    self.removeBundleInfo(id: bundleId)
                    logger.info("Deleted orphan bundle directory")
                    logger.debug("Bundle ID: \(bundleId)")
                } catch {
                    logger.error("Failed to delete orphan bundle directory")
                    logger.debug("Bundle ID: \(bundleId), Error: \(error.localizedDescription)")
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
            let contents = try fileManager.contentsOfDirectory(
                at: libraryDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

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
                if !folderName.hasPrefix(tempUnzipPrefix) {
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

    func cleanupOldDownloadTempFiles() {
        let fileManager = FileManager.default
        guard let documentsDir = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return
        }

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: documentsDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            let oneHourAgo = Date().addingTimeInterval(-3600)

            for url in contents {
                let fileName = url.lastPathComponent
                // Only cleanup package_*.tmp and update_*.dat files
                let isPackageTemp = fileName.hasPrefix("package_") && fileName.hasSuffix(".tmp")
                let isUpdateTemp = fileName.hasPrefix("update_") && fileName.hasSuffix(".dat")
                let isDownloadTemp = isPackageTemp || isUpdateTemp
                if !isDownloadTemp {
                    continue
                }

                // Only delete files older than 1 hour
                let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey]
                if let modDate = try? url.resourceValues(forKeys: resourceKeys).contentModificationDate,
                   modDate < oneHourAgo {
                    do {
                        try fileManager.removeItem(at: url)
                        logger.debug("Deleted old download temp file: \(fileName)")
                    } catch {
                        let errMsg = error.localizedDescription
                        logger.debug("Failed to delete old download temp file: \(fileName), Error: \(errMsg)")
                    }
                }
            }
        } catch {
            let errMsg = error.localizedDescription
            logger.debug("Failed to enumerate documents directory for temp file cleanup: \(errMsg)")
        }
    }
}
