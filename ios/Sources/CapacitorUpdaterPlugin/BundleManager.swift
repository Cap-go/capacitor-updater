/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation

/// Manages bundle operations (list, delete, set, reset, get) for the CapacitorUpdater plugin.
class BundleManager {
    private let logger: Logger

    // Directory paths
    private let libraryDir: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
    private let bundleDirectory: String = "NoCloud/ionic_built_snapshots"
    private let DEFAULT_FOLDER: String = ""

    // UserDefaults keys
    let CAP_SERVER_PATH: String = "serverBasePath"
    private let INFO_SUFFIX: String = "_info"
    private let FALLBACK_VERSION: String = "pastVersion"
    private let NEXT_VERSION: String = "nextVersion"
    private let TEMP_UNZIP_PREFIX: String = "capgo_unzip_"

    // Dependencies
    private let sendStats: (String, String?, String?) -> Void

    init(logger: Logger, sendStats: @escaping (String, String?, String?) -> Void) {
        self.logger = logger
        self.sendStats = sendStats
    }

    // MARK: - Bundle Directory Operations

    /// Get the directory URL for a bundle
    func getBundleDirectory(id: String) -> URL {
        return libraryDir.appendingPathComponent(bundleDirectory).appendingPathComponent(id)
    }

    /// Check if a bundle exists on disk
    func bundleExists(id: String) -> Bool {
        let destPersist = getBundleDirectory(id: id)
        let indexPersist = destPersist.appendingPathComponent("index.html")
        let bundleInfo = getBundleInfo(id: id)
        if destPersist.exist &&
            destPersist.isDirectory &&
            !indexPersist.isDirectory &&
            indexPersist.exist &&
            !bundleInfo.isDeleted() {
            return true
        }
        return false
    }

    // MARK: - Bundle Listing

    /// List all bundles
    func list(raw: Bool = false) -> [BundleInfo] {
        if !raw {
            let dest = libraryDir.appendingPathComponent(bundleDirectory)
            do {
                let files = try FileManager.default.contentsOfDirectory(atPath: dest.path)
                var res: [BundleInfo] = []
                logger.info("list File : \(dest.path)")
                if dest.exist {
                    for id in files {
                        res.append(getBundleInfo(id: id))
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
                getBundleInfo(id: $0)
            }
        }
    }

    // MARK: - Bundle Deletion

    /// Delete a bundle by ID
    func delete(id: String, removeInfo: Bool = true) -> Bool {
        let deleted = getBundleInfo(id: id)
        if deleted.isBuiltin() || getCurrentBundleId() == id {
            logger.info("Cannot delete current or builtin bundle")
            logger.debug("Bundle ID: \(id)")
            return false
        }

        // Check if this is the next bundle and prevent deletion if it is
        if let next = getNextBundle(),
           !next.isDeleted() &&
            !next.isErrorStatus() &&
            next.getId() == id {
            logger.info("Cannot delete the next bundle")
            logger.debug("Bundle ID: \(id)")
            return false
        }

        let destPersist = libraryDir.appendingPathComponent(bundleDirectory).appendingPathComponent(id)
        do {
            try FileManager.default.removeItem(atPath: destPersist.path)
        } catch {
            logger.error("Bundle folder not removed")
            logger.debug("Path: \(destPersist.path)")
            // even if, we don't care. Android doesn't care
            if removeInfo {
                removeBundleInfo(id: id)
            }
            sendStats("delete", deleted.getVersionName(), nil)
            return false
        }
        if removeInfo {
            removeBundleInfo(id: id)
        } else {
            saveBundleInfo(id: id, bundle: deleted.setStatus(status: BundleStatus.DELETED.localizedString))
        }
        logger.info("Bundle deleted successfully")
        logger.debug("Version: \(deleted.getVersionName())")
        sendStats("delete", deleted.getVersionName(), nil)
        return true
    }

    // MARK: - Bundle Set/Reset

    /// Set the current bundle
    func set(bundle: BundleInfo) -> Bool {
        return set(id: bundle.getId())
    }

    /// Set the current bundle by ID
    func set(id: String) -> Bool {
        let newBundle = getBundleInfo(id: id)
        if newBundle.isBuiltin() {
            reset()
            return true
        }
        if bundleExists(id: id) {
            let currentBundleName = getCurrentBundle().getVersionName()
            setCurrentBundle(bundle: getBundleDirectory(id: id).path)
            setBundleStatus(id: id, status: BundleStatus.PENDING)
            sendStats("set", newBundle.getVersionName(), currentBundleName)
            return true
        }
        setBundleStatus(id: id, status: BundleStatus.ERROR)
        sendStats("set_fail", newBundle.getVersionName(), nil)
        return false
    }

    /// Auto-reset if bundle doesn't exist
    func autoReset() {
        let currentBundle = getCurrentBundle()
        if !currentBundle.isBuiltin() && !bundleExists(id: currentBundle.getId()) {
            logger.info("Folder at bundle path does not exist. Triggering reset.")
            reset()
        }
    }

    /// Reset to builtin version
    func reset(isInternal: Bool = false) {
        logger.info("reset: \(isInternal)")
        let currentBundleName = getCurrentBundle().getVersionName()
        setCurrentBundle(bundle: "")
        setFallbackBundle(fallback: nil)
        _ = setNextBundle(next: nil)
        if !isInternal {
            sendStats("reset", getCurrentBundle().getVersionName(), currentBundleName)
        }
    }

    /// Mark a bundle as successful
    func setSuccess(bundle: BundleInfo, autoDeletePrevious: Bool) {
        setBundleStatus(id: bundle.getId(), status: BundleStatus.SUCCESS)
        let fallback = getFallbackBundle()
        logger.info("Fallback bundle is: \(fallback.toString())")
        logger.info("Version successfully loaded: \(bundle.toString())")
        if autoDeletePrevious && !fallback.isBuiltin() && fallback.getId() != bundle.getId() {
            let res = delete(id: fallback.getId())
            if res {
                logger.info("Deleted previous bundle")
                logger.debug("Bundle: \(fallback.toString())")
            } else {
                logger.error("Failed to delete previous bundle")
                logger.debug("Bundle: \(fallback.toString())")
            }
        }
        setFallbackBundle(fallback: bundle)
    }

    /// Mark a bundle as error
    func setError(bundle: BundleInfo) {
        setBundleStatus(id: bundle.getId(), status: BundleStatus.ERROR)
    }

    // MARK: - Bundle Info Operations

    /// Get bundle info by ID
    func getBundleInfo(id: String?) -> BundleInfo {
        var trueId = BundleInfo.VERSION_UNKNOWN
        if let id = id {
            trueId = id
        }
        let result: BundleInfo
        if BundleInfo.ID_BUILTIN == trueId {
            result = BundleInfo(id: trueId, version: "", status: BundleStatus.SUCCESS, checksum: "")
        } else if BundleInfo.VERSION_UNKNOWN == trueId {
            result = BundleInfo(id: trueId, version: "", status: BundleStatus.ERROR, checksum: "")
        } else {
            do {
                result = try UserDefaults.standard.getObj(forKey: "\(trueId)\(INFO_SUFFIX)", castTo: BundleInfo.self)
            } catch {
                logger.error("Failed to parse bundle info")
                logger.debug("Bundle ID: \(trueId), Error: \(error.localizedDescription)")
                result = BundleInfo(id: trueId, version: "", status: BundleStatus.PENDING, checksum: "")
            }
        }
        return result
    }

    /// Get bundle info by version name
    func getBundleInfoByVersionName(version: String) -> BundleInfo? {
        let installed = list()
        for bundle in installed {
            if bundle.getVersionName() == version {
                return bundle
            }
        }
        return nil
    }

    /// Save bundle info
    func saveBundleInfo(id: String, bundle: BundleInfo?) {
        if let bundle = bundle, (bundle.isBuiltin() || bundle.isUnknown()) {
            logger.info("Not saving info for bundle [\(id)] \(bundle.toString())")
            return
        }
        if bundle == nil {
            logger.info("Removing info for bundle [\(id)]")
            UserDefaults.standard.removeObject(forKey: "\(id)\(INFO_SUFFIX)")
        } else {
            let update = bundle!.setId(id: id)
            logger.info("Storing info for bundle [\(id)] \(update.toString())")
            do {
                try UserDefaults.standard.setObj(update, forKey: "\(id)\(INFO_SUFFIX)")
            } catch {
                logger.error("Failed to save bundle info")
                logger.debug("Bundle ID: \(id), Error: \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.synchronize()
    }

    private func removeBundleInfo(id: String) {
        saveBundleInfo(id: id, bundle: nil)
    }

    private func setBundleStatus(id: String, status: BundleStatus) {
        logger.info("Setting status for bundle [\(id)] to \(status)")
        let info = getBundleInfo(id: id)
        saveBundleInfo(id: id, bundle: info.setStatus(status: status.localizedString))
    }

    // MARK: - Current Bundle Operations

    /// Get the current bundle
    func getCurrentBundle() -> BundleInfo {
        return getBundleInfo(id: getCurrentBundleId())
    }

    /// Get the current bundle ID
    func getCurrentBundleId() -> String {
        guard let bundlePath = UserDefaults.standard.string(forKey: CAP_SERVER_PATH) else {
            return BundleInfo.ID_BUILTIN
        }
        if bundlePath.isEmpty {
            return BundleInfo.ID_BUILTIN
        }
        let bundleID = bundlePath.components(separatedBy: "/").last ?? bundlePath
        return bundleID
    }

    /// Check if using builtin
    func isUsingBuiltin() -> Bool {
        return (UserDefaults.standard.string(forKey: CAP_SERVER_PATH) ?? "") == DEFAULT_FOLDER
    }

    /// Set the current bundle path
    func setCurrentBundle(bundle: String) {
        UserDefaults.standard.set(bundle, forKey: CAP_SERVER_PATH)
        UserDefaults.standard.synchronize()
        logger.info("Current bundle set to: \(bundle.isEmpty ? BundleInfo.ID_BUILTIN : bundle)")
    }

    // MARK: - Fallback Bundle Operations

    /// Get the fallback bundle
    func getFallbackBundle() -> BundleInfo {
        let id = UserDefaults.standard.string(forKey: FALLBACK_VERSION) ?? BundleInfo.ID_BUILTIN
        return getBundleInfo(id: id)
    }

    /// Set the fallback bundle
    func setFallbackBundle(fallback: BundleInfo?) {
        UserDefaults.standard.set(fallback == nil ? BundleInfo.ID_BUILTIN : fallback!.getId(), forKey: FALLBACK_VERSION)
        UserDefaults.standard.synchronize()
    }

    // MARK: - Next Bundle Operations

    /// Get the next bundle to be installed
    func getNextBundle() -> BundleInfo? {
        let id = UserDefaults.standard.string(forKey: NEXT_VERSION)
        return getBundleInfo(id: id)
    }

    /// Set the next bundle to be installed
    func setNextBundle(next: String?) -> Bool {
        guard let nextId = next else {
            UserDefaults.standard.removeObject(forKey: NEXT_VERSION)
            UserDefaults.standard.synchronize()
            return false
        }
        let newBundle = getBundleInfo(id: nextId)
        if !newBundle.isBuiltin() && !bundleExists(id: nextId) {
            return false
        }
        UserDefaults.standard.set(nextId, forKey: NEXT_VERSION)
        UserDefaults.standard.synchronize()
        setBundleStatus(id: nextId, status: BundleStatus.PENDING)
        return true
    }

    // MARK: - Cleanup Operations

    /// Cleanup delta cache folder
    func cleanupDeltaCache(threadToCheck: Thread? = nil) {
        // Check if thread was cancelled
        if let thread = threadToCheck, thread.isCancelled {
            logger.warn("cleanupDeltaCache was cancelled before starting")
            return
        }

        let cacheFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("capgo_downloads")
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

    /// Cleanup download directories that are not in the allowed list
    func cleanupDownloadDirectories(allowedIds: Set<String>, threadToCheck: Thread? = nil) {
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
                    removeBundleInfo(id: id)
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

    /// Cleanup orphaned temp unzip folders
    func cleanupOrphanedTempFolders(threadToCheck: Thread? = nil) {
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
}
