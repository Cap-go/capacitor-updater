/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation

// MARK: - Bundle Operations
extension CapgoUpdater {
    public func list(raw: Bool = false) -> [BundleInfo] {
        if !raw {
            let dest: URL = libraryDir.appendingPathComponent(bundleDirectory)
            do {
                let files: [String] = try FileManager.default.contentsOfDirectory(atPath: dest.path)
                var res: [BundleInfo] = []
                logger.info("list File : \(dest.path)")
                if dest.exist {
                    for bundleId: String in files {
                        res.append(self.getBundleInfo(id: bundleId))
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

    public func getBundleDirectory(id: String) -> URL {
        return libraryDir.appendingPathComponent(self.bundleDirectory).appendingPathComponent(id)
    }

    public func set(bundle: BundleInfo) -> Bool {
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
        let newVersion = self.getBundleInfo(id: bundle.getId())
        let fallback = self.getFallbackBundle()
        if autoDeletePrevious && !fallback.isBuiltin() && fallback.getId() != newVersion.getId() {
            logger.info("Auto deleting previous bundle")
            logger.debug("Bundle: \(fallback.toString())")
            _ = self.delete(id: fallback.getId())
        }
        self.setFallbackBundle(fallback: bundle)
    }

    public func setError(bundle: BundleInfo) {
        self.setBundleStatus(id: bundle.getId(), status: BundleStatus.ERROR)
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
                result = try UserDefaults.standard.getObj(forKey: "\(trueId)\(self.infoSuffix)", castTo: BundleInfo.self)
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
        for bundle in installed where bundle.getVersionName() == version {
            return bundle
        }
        return nil
    }

    public func saveBundleInfo(id: String, bundle: BundleInfo?) {
        if bundle != nil && (bundle!.isBuiltin() || bundle!.isUnknown()) {
            logger.info("Not saving info for bundle [\(id)] \(bundle?.toString() ?? "")")
            return
        }
        if bundle == nil {
            logger.info("Removing info for bundle [\(id)]")
            UserDefaults.standard.removeObject(forKey: "\(id)\(self.infoSuffix)")
        } else {
            let update = bundle!.setId(id: id)
            logger.info("Storing info for bundle [\(id)] \(update.toString())")
            do {
                try UserDefaults.standard.setObj(update, forKey: "\(id)\(self.infoSuffix)")
            } catch {
                logger.error("Failed to save bundle info")
                logger.debug("Bundle ID: \(id), Error: \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.synchronize()
    }

    func setBundleStatus(id: String, status: BundleStatus) {
        logger.info("Setting status for bundle [\(id)] to \(status)")
        let info = self.getBundleInfo(id: id)
        self.saveBundleInfo(id: id, bundle: info.setStatus(status: status.localizedString))
    }

    public func getCurrentBundle() -> BundleInfo {
        return self.getBundleInfo(id: self.getCurrentBundleId())
    }

    public func getCurrentBundleId() -> String {
        guard let bundlePath: String = UserDefaults.standard.string(forKey: self.capServerPath) else {
            return BundleInfo.ID_BUILTIN
        }
        if (bundlePath).isEmpty {
            return BundleInfo.ID_BUILTIN
        }
        let bundleID: String = bundlePath.components(separatedBy: "/").last ?? bundlePath
        return bundleID
    }

    public func isUsingBuiltin() -> Bool {
        return (UserDefaults.standard.string(forKey: self.capServerPath) ?? "") == self.defaultFolder
    }

    public func getFallbackBundle() -> BundleInfo {
        let id: String = UserDefaults.standard.string(forKey: self.fallbackVersionKey) ?? BundleInfo.ID_BUILTIN
        return self.getBundleInfo(id: id)
    }

    func setFallbackBundle(fallback: BundleInfo?) {
        UserDefaults.standard.set(fallback == nil ? BundleInfo.ID_BUILTIN : fallback!.getId(), forKey: self.fallbackVersionKey)
        UserDefaults.standard.synchronize()
    }

    public func getNextBundle() -> BundleInfo? {
        let id: String? = UserDefaults.standard.string(forKey: self.nextVersionKey)
        return self.getBundleInfo(id: id)
    }

    public func setNextBundle(next: String?) -> Bool {
        guard let nextId: String = next else {
            UserDefaults.standard.removeObject(forKey: self.nextVersionKey)
            UserDefaults.standard.synchronize()
            return false
        }
        let newBundle: BundleInfo = self.getBundleInfo(id: nextId)
        if !newBundle.isBuiltin() && !self.bundleExists(id: nextId) {
            return false
        }
        UserDefaults.standard.set(nextId, forKey: self.nextVersionKey)
        UserDefaults.standard.synchronize()
        self.setBundleStatus(id: nextId, status: BundleStatus.PENDING)
        return true
    }

    func setCurrentBundle(bundle: String) {
        UserDefaults.standard.set(bundle, forKey: self.capServerPath)
        UserDefaults.standard.synchronize()
        logger.info("Current bundle set to: \((bundle ).isEmpty ? BundleInfo.ID_BUILTIN : bundle)")
    }
}
