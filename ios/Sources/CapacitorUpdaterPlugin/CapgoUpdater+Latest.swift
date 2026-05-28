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
    func createInfoObject(appIdOverride: String? = nil) -> InfoObject {
        return InfoObject(
            platform: "ios",
            deviceId: self.deviceID,
            appId: appIdOverride ?? self.appId,
            customId: self.customId,
            versionBuild: self.versionBuild,
            versionCode: self.versionCode,
            versionOs: self.versionOs,
            versionName: self.getCurrentBundle().getVersionName(),
            pluginVersion: self.pluginVersion,
            isEmulator: self.isEmulator(),
            isProd: self.isProd(),
            action: nil,
            channel: nil,
            defaultChannel: self.defaultChannel,
            keyId: self.cachedKeyId
        )
    }

    func applyLatestResponse(_ value: AppVersionDec?, to latest: AppVersion) {
        if let url = value?.url {
            latest.url = url
        }
        if let checksum = value?.checksum {
            latest.checksum = checksum
        }
        if let version = value?.version {
            latest.version = version
        }
        if let major = value?.major {
            latest.major = major
        }
        if let breaking = value?.breaking {
            latest.breaking = breaking
        }
        if let error = value?.error {
            latest.error = error
        }
        if let kind = value?.kind {
            latest.kind = kind
        }
        if let message = value?.message {
            latest.message = message
        }
        if let sessionKey = value?.sessionKey {
            latest.sessionKey = sessionKey
        }
        if let data = value?.data {
            latest.data = data
        }
        if let manifest = value?.manifest {
            latest.manifest = manifest
        }
        if let link = value?.link {
            latest.link = link
        }
        if let comment = value?.comment {
            latest.comment = comment
        }
    }

    func getLatestImpl(url: URL, channel: String?, appIdOverride: String? = nil) -> AppVersion {
        let latest: AppVersion = AppVersion()
        var parameters: InfoObject = self.createInfoObject(appIdOverride: appIdOverride)
        if let channel = channel {
            parameters.defaultChannel = channel
        }
        guard let request = createRequest(url: url, method: "POST", parameters: parameters.toParameters()) else {
            latest.message = "Error getting Latest"
            latest.error = "request_error"
            latest.kind = "failed"
            return latest
        }

        let result = performRequest(request, label: "getLatest")
        latest.statusCode = result.response?.statusCode ?? 0

        if result.timedOut {
            latest.message = "Error getting Latest"
            latest.error = "timeout_error"
            latest.kind = "failed"
            return latest
        }

        if let error = result.error {
            self.logger.error("Error getting latest version")
            self.logger.debug("Error: \(error.localizedDescription)")
            latest.message = "Error getting Latest"
            latest.error = "response_error"
            latest.kind = "failed"
            return latest
        }

        guard let data = result.data else {
            self.logger.error("Missing latest version response data")
            latest.message = "Error getting Latest"
            latest.error = "response_error"
            latest.kind = "failed"
            return latest
        }

        if self.checkAndHandleRateLimitResponse(statusCode: latest.statusCode) {
            latest.message = "Rate limit exceeded"
            latest.error = "rate_limit_exceeded"
            latest.kind = "failed"
            return latest
        }

        guard let responseValue = try? JSONDecoder().decode(AppVersionDec.self, from: data) else {
            self.logger.error("Error decoding latest version")
            latest.message = "Error getting Latest"
            latest.error = "decode_error"
            latest.kind = "failed"
            return latest
        }

        applyLatestResponse(responseValue, to: latest)

        if latest.statusCode < 200 || latest.statusCode >= 300 {
            if latest.message == nil || latest.message?.isEmpty == true {
                latest.message = responseValue.message ?? "Server error: \(latest.statusCode)"
            }
            if latest.error == nil || latest.error?.isEmpty == true {
                latest.error = responseValue.error ?? "response_error"
            }
            if latest.kind == nil || latest.kind?.isEmpty == true {
                latest.kind = responseValue.kind ?? "failed"
            }
            return latest
        }

        return latest
    }

    func setCurrentBundle(bundle: String) {
        UserDefaults.standard.set(bundle, forKey: self.capServerPathKey)
        UserDefaults.standard.synchronize()
        logger.info("Current bundle set to: \((bundle ).isEmpty ? BundleInfo.idBuiltin : bundle)")
    }

    static func shouldResetForForeignBundle(bundlePath: String?, isBuiltin: Bool, hasStoredBundleInfo: Bool) -> Bool {
        guard let bundlePath, !bundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return !isBuiltin && !hasStoredBundleInfo
    }

    func hasStoredBundleInfo(id: String) -> Bool {
        guard !id.isEmpty,
              id != BundleInfo.idBuiltin,
              id != BundleInfo.versionUnknown else {
            return false
        }
        return UserDefaults.standard.object(forKey: "\(id)\(self.infoSuffix)") != nil
    }

    // Per-download temp file paths to prevent collisions when multiple downloads run concurrently
    func tempDataPath(for id: String) -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("package_\(id).tmp")
    }

    func updateInfoPath(for id: String) -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("update_\(id).dat")
    }

    func verifyChecksum(file: URL, expectedHash: String) -> Bool {
        let actualHash =    CryptoCipher.calcChecksum(filePath: file)
        return actualHash == expectedHash
    }

    func resolveManifestFileHash(entry: ManifestEntry, sessionKey: String) -> String? {
        guard var fileHash = entry.fileHash, !fileHash.isEmpty else {
            return nil
        }
        if !self.publicKey.isEmpty && !sessionKey.isEmpty {
            do {
                fileHash = try CryptoCipher.decryptChecksum(checksum: fileHash, publicKey: self.publicKey)
            } catch {
                logger.error("Checksum decryption failed while checking missing manifest files")
                logger.debug("File: \(entry.fileName ?? "unknown"), Error: \(error.localizedDescription)")
                return nil
            }
        }
        return fileHash
    }

    func isManifestEntryAvailableLocally(entry: ManifestEntry, sessionKey: String) -> Bool {
        guard let fileName = entry.fileName,
              let fileHash = resolveManifestFileHash(entry: entry, sessionKey: sessionKey) else {
            return false
        }

        let builtinFolder = Bundle.main.bundleURL.appendingPathComponent("public")
        let builtinFilePath = builtinFolder.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: builtinFilePath.path) && verifyChecksum(file: builtinFilePath, expectedHash: fileHash) {
            return true
        }

        let fileNameWithoutPath = (fileName as NSString).lastPathComponent
        let isBrotli = fileName.hasSuffix(".br")
        let cacheBaseName = isBrotli ? String(fileNameWithoutPath.dropLast(3)) : fileNameWithoutPath
        let cacheFilePath = cacheFolder.appendingPathComponent("\(fileHash)_\(cacheBaseName)")
        if FileManager.default.fileExists(atPath: cacheFilePath.path) && verifyChecksum(file: cacheFilePath, expectedHash: fileHash) {
            return true
        }

        if isBrotli {
            let legacyCacheFilePath = cacheFolder.appendingPathComponent("\(fileHash)_\(fileNameWithoutPath)")
            if FileManager.default.fileExists(atPath: legacyCacheFilePath.path) && verifyChecksum(file: legacyCacheFilePath, expectedHash: fileHash) {
                return true
            }
        }

        return false
    }

    public func getMissingBundleFiles(manifest: [ManifestEntry], sessionKey: String) -> [ManifestEntry] {
        return manifest.filter { entry in
            !isManifestEntryAvailableLocally(entry: entry, sessionKey: sessionKey)
        }
    }

    public func missingBundleFilesResult(manifest: [ManifestEntry], sessionKey: String) -> [String: Any] {
        let missing = getMissingBundleFiles(manifest: manifest, sessionKey: sessionKey)
        return [
            "missing": missing.map { $0.toDict() },
            "total": manifest.count,
            "missingCount": missing.count,
            "reusableCount": manifest.count - missing.count
        ]
    }

    func manifestSizeUrl(from updateUrl: URL) -> URL {
        var components = URLComponents(url: updateUrl, resolvingAgainstBaseURL: false)
        let path = components?.path ?? updateUrl.path
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = trimmedPath == ""
            ? "/manifest_size"
            : "/\(trimmedPath)/manifest_size"
        components?.query = nil
        return components?.url ?? updateUrl.appendingPathComponent("manifest_size")
    }

    func unavailableBundleSizeResult(manifest: [ManifestEntry], error: String) -> [String: Any] {
        return [
            "totalSize": 0,
            "knownFiles": 0,
            "unknownFiles": manifest.count,
            "files": manifest.map {
                var dict = $0.toDict()
                dict["error"] = error
                return dict
            }
        ]
    }

    public func getBundleDownloadSize(updateUrl: URL, version: String?, manifest: [ManifestEntry]) -> [String: Any] {
        if manifest.isEmpty {
            return [
                "totalSize": 0,
                "knownFiles": 0,
                "unknownFiles": 0,
                "files": []
            ]
        }

        var parameters = self.createInfoObject().toParameters()
        parameters["version"] = version ?? ""
        parameters["manifest"] = manifest.map { $0.toDict() }

        guard let request = createRequest(url: manifestSizeUrl(from: updateUrl), method: "POST", parameters: parameters) else {
            return unavailableBundleSizeResult(manifest: manifest, error: "request_error")
        }

        let result = performRequest(request, label: "getBundleDownloadSize")
        if result.timedOut {
            return unavailableBundleSizeResult(manifest: manifest, error: "timeout_error")
        }
        if let error = result.error {
            logger.error("Error getting bundle download size")
            logger.debug("Error: \(error.localizedDescription)")
            return unavailableBundleSizeResult(manifest: manifest, error: "response_error")
        }
        guard let data = result.data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return unavailableBundleSizeResult(manifest: manifest, error: "parse_error")
        }

        let statusCode = result.response?.statusCode ?? 0
        if statusCode < 200 || statusCode >= 300 {
            return unavailableBundleSizeResult(manifest: manifest, error: "response_error")
        }

        return json
    }
}
