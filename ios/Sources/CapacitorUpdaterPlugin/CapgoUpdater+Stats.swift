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
    func sendStatsWithMetadata(action: String, versionName: String?, oldVersionName: String?, metadata: [String: String]?) {
        if previewSession {
            logger.debug("Skipping sendStats during preview session.")
            return
        }

        // Check if rate limit was exceeded
        if CapgoUpdater.rateLimitExceeded {
            logger.debug("Skipping sendStats due to rate limit (429). Stats will resume after app restart.")
            return
        }

        guard !statsUrl.isEmpty else {
            return
        }

        let resolvedVersionName = versionName ?? getCurrentBundle().getVersionName()
        let info = createInfoObject()

        let event = StatsEvent(
            platform: info.platform,
            deviceId: info.deviceId,
            appId: info.appId,
            customId: info.customId,
            versionBuild: info.versionBuild,
            versionCode: info.versionCode,
            versionOs: info.versionOs,
            versionName: resolvedVersionName,
            oldVersionName: oldVersionName ?? "",
            pluginVersion: info.pluginVersion,
            isEmulator: info.isEmulator,
            isProd: info.isProd,
            action: action,
            channel: info.channel,
            defaultChannel: info.defaultChannel,
            keyId: info.keyId,
            metadata: metadata,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )

        statsQueueLock.lock()
        statsQueue.append(event)
        statsQueueLock.unlock()

        ensureStatsTimerStarted()
    }

    func ensureStatsTimerStarted() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.statsFlushTimer == nil || !self.statsFlushTimer!.isValid {
                // Use closure-based timer to avoid strong reference cycle
                self.statsFlushTimer = Timer.scheduledTimer(
                    withTimeInterval: CapgoUpdater.statsFlushInterval,
                    repeats: true
                ) { [weak self] _ in
                    self?.flushStatsQueue()
                }
            }
        }
    }

    func flushStatsQueue() {
        statsQueueLock.lock()
        guard !statsQueue.isEmpty else {
            statsQueueLock.unlock()
            return
        }
        let eventsToSend = statsQueue
        statsQueue.removeAll()
        statsQueueLock.unlock()

        operationQueue.maxConcurrentOperationCount = 1

        let operation = BlockOperation {
            let semaphore = DispatchSemaphore(value: 0)
            self.alamofireSession.request(
                self.statsUrl,
                method: .post,
                parameters: eventsToSend,
                encoder: JSONParameterEncoder.default,
                requestModifier: { $0.timeoutInterval = self.timeout }
            ).responseData { response in
                // Check for 429 rate limit
                if self.checkAndHandleRateLimitResponse(statusCode: response.response?.statusCode) {
                    semaphore.signal()
                    return
                }

                switch response.result {
                case .success:
                    self.logger.info("Stats batch sent successfully")
                    self.logger.debug("Sent \(eventsToSend.count) events")
                case let .failure(error):
                    self.logger.error("Error sending stats batch")
                    self.logger.debug("Response: \(response.value?.debugDescription ?? "nil"), Error: \(error.localizedDescription)")
                }
                semaphore.signal()
            }
            semaphore.wait()
        }
        operationQueue.addOperation(operation)
    }

    func getBundleInfoImpl(id: String?) -> BundleInfo {
        var trueId = BundleInfo.versionUnknown
        if id != nil {
            trueId = id!
        }
        let result: BundleInfo
        if BundleInfo.idBuiltin == trueId {
            result = BundleInfo(id: trueId, version: self.versionBuild, status: BundleStatus.SUCCESS, checksum: "")
        } else if BundleInfo.versionUnknown == trueId {
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

    func getBundleInfoByVersionNameImpl(version: String) -> BundleInfo? {
        let installed: [BundleInfo] = self.list()
        for installedBundle in installed {
            if installedBundle.getVersionName() == version {
                return installedBundle
            }
        }
        return nil
    }

    func removeBundleInfo(id: String) {
        self.saveBundleInfo(id: id, bundle: nil)
    }

    func saveBundleInfoImpl(id: String, bundle: BundleInfo?) {
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
    }

    func setBundleStatus(id: String, status: BundleStatus) {
        logger.info("Setting status for bundle [\(id)] to \(status)")
        let info = self.getBundleInfo(id: id)
        self.saveBundleInfo(id: id, bundle: info.setStatus(status: status.storedValue))
    }

    func getCurrentBundleImpl() -> BundleInfo {
        return self.getBundleInfo(id: self.getCurrentBundleId())
    }

    public func getCurrentBundleId() -> String {
        guard let bundlePath: String = UserDefaults.standard.string(forKey: self.capServerPathKey) else {
            return BundleInfo.idBuiltin
        }
        let normalizedPath = bundlePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedPath.isEmpty || normalizedPath == self.defaultFolder {
            return BundleInfo.idBuiltin
        }
        let bundleID: String = normalizedPath.components(separatedBy: "/").last ?? normalizedPath
        return bundleID
    }

    public func isUsingBuiltin() -> Bool {
        return (UserDefaults.standard.string(forKey: self.capServerPathKey) ?? "") == self.defaultFolder
    }

    func getFallbackBundleImpl() -> BundleInfo {
        let id: String = UserDefaults.standard.string(forKey: self.fallbackVersionKey) ?? BundleInfo.idBuiltin
        return self.getBundleInfo(id: id)
    }

    func setFallbackBundle(fallback: BundleInfo?) {
        UserDefaults.standard.set(fallback == nil ? BundleInfo.idBuiltin : fallback!.getId(), forKey: self.fallbackVersionKey)
        UserDefaults.standard.synchronize()
    }

    func getNextBundleImpl() -> BundleInfo? {
        let id: String? = UserDefaults.standard.string(forKey: self.nextVersionKey)
        return self.getBundleInfo(id: id)
    }

    public func getPreviewFallbackBundle() -> BundleInfo? {
        guard let id = UserDefaults.standard.string(forKey: self.previewFallbackVersionKey) else {
            return nil
        }
        let bundle = self.getBundleInfo(id: id)
        if !bundle.isBuiltin() && !self.bundleExists(id: id) {
            _ = self.setPreviewFallbackBundle(fallback: nil)
            return nil
        }
        return bundle
    }

    public func setPreviewFallbackBundle(fallback: String?) -> Bool {
        guard let fallbackId = fallback else {
            UserDefaults.standard.removeObject(forKey: self.previewFallbackVersionKey)
            UserDefaults.standard.synchronize()
            return true
        }
        let newBundle: BundleInfo = self.getBundleInfo(id: fallbackId)
        if !newBundle.isBuiltin() && !self.bundleExists(id: fallbackId) {
            return false
        }
        UserDefaults.standard.set(fallbackId, forKey: self.previewFallbackVersionKey)
        UserDefaults.standard.synchronize()
        return true
    }

    func setNextBundleImpl(next: String?) -> Bool {
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
        self.sendStats(action: "set_next", versionName: newBundle.getVersionName(), oldVersionName: self.getCurrentBundle().getVersionName())
        self.notifyListeners("setNext", ["bundle": newBundle.toJSON()])
        return true
    }
}
