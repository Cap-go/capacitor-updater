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

    func getLocalUpdateVersion(for id: String) -> String { // Return the version that was tried to be downloaded on last download attempt
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

        if let previewFallback = self.getPreviewFallbackBundle(),
           !previewFallback.isDeleted(),
           !previewFallback.isErrorStatus(),
           previewFallback.getId() == id {
            logger.info("Cannot delete the preview fallback bundle")
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
            self.saveBundleInfo(id: id, bundle: deleted.setStatus(status: BundleStatus.DELETED.storedValue))
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

    struct ResetState {
        let currentBundlePath: String
        let fallbackBundleId: String
        let nextBundleId: String?
    }

    func captureResetStateImpl() -> ResetState {
        ResetState(
            currentBundlePath: UserDefaults.standard.string(forKey: self.capServerPathKey) ?? self.defaultFolder,
            fallbackBundleId: UserDefaults.standard.string(forKey: self.fallbackVersionKey) ?? BundleInfo.idBuiltin,
            nextBundleId: UserDefaults.standard.string(forKey: self.nextVersionKey)
        )
    }

    func restoreResetStateImpl(_ state: ResetState) {
        let currentBundlePath = state.currentBundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? self.defaultFolder
            : state.currentBundlePath
        let fallbackBundleId = state.fallbackBundleId.isEmpty ? BundleInfo.idBuiltin : state.fallbackBundleId

        self.setCurrentBundle(bundle: currentBundlePath)
        UserDefaults.standard.set(fallbackBundleId, forKey: self.fallbackVersionKey)
        if let nextBundleId = state.nextBundleId, !nextBundleId.isEmpty {
            UserDefaults.standard.set(nextBundleId, forKey: self.nextVersionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.nextVersionKey)
        }
        UserDefaults.standard.synchronize()
    }

    func prepareResetStateForTransitionImpl() {
        self.setCurrentBundle(bundle: "")
        self.setFallbackBundle(fallback: Optional<BundleInfo>.none)
        _ = self.setNextBundle(next: Optional<String>.none)
    }

    func finalizeResetTransitionImpl(previousBundleName: String, isInternal: Bool) {
        if !isInternal {
            self.sendStats(action: "reset", versionName: self.getCurrentBundle().getVersionName(), oldVersionName: previousBundleName)
        }
    }

    func canSetImpl(bundle: BundleInfo) -> Bool {
        bundle.isBuiltin() || self.bundleExists(id: bundle.getId())
    }

    func setImpl(bundle: BundleInfo) -> Bool {
        return self.set(id: bundle.getId())
    }

    func bundleExists(id: String) -> Bool {
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

    func stagePendingReloadImpl(bundle: BundleInfo) -> Bool {
        guard !bundle.isBuiltin(), bundleExists(id: bundle.getId()) else {
            return false
        }
        self.setCurrentBundle(bundle: self.getBundleDirectory(id: bundle.getId()).path)
        return true
    }

    func stagePreviewFallbackReload(bundle: BundleInfo) -> Bool {
        guard !bundle.isErrorStatus() else {
            return false
        }
        if bundle.isBuiltin() {
            self.setCurrentBundle(bundle: self.defaultFolder)
            return true
        }
        guard bundleExists(id: bundle.getId()) else {
            return false
        }
        self.setCurrentBundle(bundle: self.getBundleDirectory(id: bundle.getId()).path)
        return true
    }

    func finalizePendingReloadImpl(bundle: BundleInfo, previousBundleName: String) {
        guard !bundle.isBuiltin() else {
            return
        }
        self.sendStats(action: "set", versionName: bundle.getVersionName(), oldVersionName: previousBundleName)
    }

    public func autoReset() {
        let currentBundle: BundleInfo = self.getCurrentBundle()
        if !currentBundle.isBuiltin() && !self.bundleExists(id: currentBundle.getId()) {
            logger.info("Folder at bundle path does not exist. Triggering reset.")
            self.reset()
            return
        }
        let bundlePath = UserDefaults.standard.string(forKey: self.capServerPathKey)
        if Self.shouldResetForForeignBundle(
            bundlePath: bundlePath,
            isBuiltin: currentBundle.isBuiltin(),
            hasStoredBundleInfo: self.hasStoredBundleInfo(id: currentBundle.getId())
        ) {
            logger.info("Current bundle id is not one of the bundle ids stored by this plugin. Triggering reset.")
            self.reset()
        }
    }

    public func reset() {
        self.reset(isInternal: false)
    }

    func resetImpl(isInternal: Bool) {
        logger.info("reset: \(isInternal)")
        let currentBundleName = self.getCurrentBundle().getVersionName()
        self.prepareResetStateForTransition()
        self.finalizeResetTransition(previousBundleName: currentBundleName, isInternal: isInternal)
    }

    public func setSuccess(bundle: BundleInfo, autoDeletePrevious: Bool) {
        self.setBundleStatus(id: bundle.getId(), status: BundleStatus.SUCCESS)
        let fallback: BundleInfo = self.getFallbackBundle()
        let previewFallback = self.getPreviewFallbackBundle()
        let fallbackIsPreviewFallback = previewFallback?.getId() == fallback.getId()
        logger.info("Fallback bundle is: \(fallback.toString())")
        logger.info("Version successfully loaded: \(bundle.toString())")
        if autoDeletePrevious && !fallback.isBuiltin() && fallback.getId() != bundle.getId() && !fallbackIsPreviewFallback {
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

}
