/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
#if canImport(ZipArchive)
import ZipArchive
#else
import SSZipArchive
#endif
import Alamofire
import Compression
import UIKit

@objc public class CapacitorUpdater: NSObject {

    private let versionCode: String = Bundle.main.versionCode ?? ""
    private let versionOs = UIDevice.current.systemVersion
    private let libraryDir: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
    private let DEFAULT_FOLDER: String = ""
    private let bundleDirectory: String = "NoCloud/ionic_built_snapshots"
    private let INFO_SUFFIX: String = "_info"
    private let FALLBACK_VERSION: String = "pastVersion"
    private let NEXT_VERSION: String = "nextVersion"
    private var unzipPercent = 0

    // Add this line to declare cacheFolder
    private let cacheFolder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("capgo_downloads")

    public static let TAG: String = "✨  Capacitor-updater:"
    public let CAP_SERVER_PATH: String = "serverBasePath"
    public var versionBuild: String = ""
    public var customId: String = ""
    public var PLUGIN_VERSION: String = ""
    public var timeout: Double = 20
    public var statsUrl: String = ""
    public var channelUrl: String = ""
    public var defaultChannel: String = ""
    public var appId: String = ""
    public var deviceID = ""
    public var publicKey: String = ""

    public var notifyDownloadRaw: (String, Int, Bool) -> Void = { _, _, _  in }
    public func notifyDownload(id: String, percent: Int, ignoreMultipleOfTen: Bool = false) {
        notifyDownloadRaw(id, percent, ignoreMultipleOfTen)
    }
    public var notifyDownload: (String, Int) -> Void = { _, _  in }

    private func calcTotalPercent(percent: Int, min: Int, max: Int) -> Int {
        return (percent * (max - min)) / 100 + min
    }

    private func randomString(length: Int) -> String {
        let letters: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in letters.randomElement()! })
    }

    private var isDevEnvironment: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private func isProd() -> Bool {
        return !self.isDevEnvironment && !self.isAppStoreReceiptSandbox() && !self.hasEmbeddedMobileProvision()
    }

    // MARK: Private
    private func hasEmbeddedMobileProvision() -> Bool {
        guard Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") == nil else {
            return true
        }
        return false
    }

    private func isAppStoreReceiptSandbox() -> Bool {

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

    private func isEmulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    // Persistent path /var/mobile/Containers/Data/Application/8C0C07BE-0FD3-4FD4-B7DF-90A88E12B8C3/Library/NoCloud/ionic_built_snapshots/FOLDER
    // Hot Reload path /var/mobile/Containers/Data/Application/8C0C07BE-0FD3-4FD4-B7DF-90A88E12B8C3/Documents/FOLDER
    // Normal /private/var/containers/Bundle/Application/8C0C07BE-0FD3-4FD4-B7DF-90A88E12B8C3/App.app/public

    private func prepareFolder(source: URL) throws {
        if !FileManager.default.fileExists(atPath: source.path) {
            do {
                try FileManager.default.createDirectory(atPath: source.path, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("\(CapacitorUpdater.TAG) Cannot createDirectory \(source.path)")
                throw CustomError.cannotCreateDirectory
            }
        }
    }

    private func deleteFolder(source: URL) throws {
        do {
            try FileManager.default.removeItem(atPath: source.path)
        } catch {
            print("\(CapacitorUpdater.TAG) File not removed. \(source.path)")
            throw CustomError.cannotDeleteDirectory
        }
    }

    private func unflatFolder(source: URL, dest: URL) throws -> Bool {
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
            print("\(CapacitorUpdater.TAG) File not moved. source: \(source.path) dest: \(dest.path)")
            throw CustomError.cannotUnflat
        }
    }

    private func unzipProgressHandler(entry: String, zipInfo: unz_file_info, entryNumber: Int, total: Int, destUnZip: URL, id: String, unzipError: inout NSError?) {
        if entry.contains("\\") {
            print("\(CapacitorUpdater.TAG) unzip: Windows path is not supported, please use unix path as required by zip RFC: \(entry)")
            self.sendStats(action: "windows_path_fail")
        }

        let fileURL = destUnZip.appendingPathComponent(entry)
        let canonicalPath = fileURL.path
        let canonicalDir = destUnZip.path

        if !canonicalPath.hasPrefix(canonicalDir) {
            self.sendStats(action: "canonical_path_fail")
            unzipError = NSError(domain: "CanonicalPathError", code: 0, userInfo: nil)
        }

        let isDirectory = entry.hasSuffix("/")
        if !isDirectory {
            let folderURL = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: folderURL.path) {
                do {
                    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    self.sendStats(action: "directory_path_fail")
                    unzipError = error as NSError
                }
            }
        }

        let newPercent = self.calcTotalPercent(percent: Int(Double(entryNumber) / Double(total) * 100), min: 75, max: 81)
        if newPercent != self.unzipPercent {
            self.unzipPercent = newPercent
            self.notifyDownload(id: id, percent: newPercent)
        }
    }

    private func saveDownloaded(sourceZip: URL, id: String, base: URL, notify: Bool) throws {
        try prepareFolder(source: base)
        let destPersist: URL = base.appendingPathComponent(id)
        let destUnZip: URL = libraryDir.appendingPathComponent(randomString(length: 10))

        self.unzipPercent = 0
        self.notifyDownload(id: id, percent: 75)

        let semaphore = DispatchSemaphore(value: 0)
        var unzipError: NSError?

        let success = SSZipArchive.unzipFile(atPath: sourceZip.path,
                                             toDestination: destUnZip.path,
                                             preserveAttributes: true,
                                             overwrite: true,
                                             nestedZipLevel: 1,
                                             password: nil,
                                             error: &unzipError,
                                             delegate: nil,
                                             progressHandler: { [weak self] (entry, zipInfo, entryNumber, total) in
                                                DispatchQueue.global(qos: .background).async {
                                                    guard let self = self else { return }
                                                    if !notify {
                                                        return
                                                    }
                                                    self.unzipProgressHandler(entry: entry, zipInfo: zipInfo, entryNumber: entryNumber, total: total, destUnZip: destUnZip, id: id, unzipError: &unzipError)
                                                }
                                             },
                                             completionHandler: { _, _, _  in
                                                semaphore.signal()
                                             })

        semaphore.wait()

        if !success || unzipError != nil {
            self.sendStats(action: "unzip_fail")
            throw unzipError ?? CustomError.cannotUnzip
        }

        if try unflatFolder(source: destUnZip, dest: destPersist) {
            try deleteFolder(source: destUnZip)
        }
    }

    private func createInfoObject() -> InfoObject {
        return InfoObject(
            platform: "ios",
            device_id: self.deviceID,
            app_id: self.appId,
            custom_id: self.customId,
            version_build: self.versionBuild,
            version_code: self.versionCode,
            version_os: self.versionOs,
            version_name: self.getCurrentBundle().getVersionName(),
            plugin_version: self.PLUGIN_VERSION,
            is_emulator: self.isEmulator(),
            is_prod: self.isProd(),
            action: nil,
            channel: nil,
            defaultChannel: self.defaultChannel
        )
    }

    public func getLatest(url: URL, channel: String?) -> AppVersion {
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        let latest: AppVersion = AppVersion()
        var parameters: InfoObject = self.createInfoObject()
        if let channel = channel {
            parameters.defaultChannel = channel
        }
        print("\(CapacitorUpdater.TAG) Auto-update parameters: \(parameters)")
        let request = AF.request(url, method: .post, parameters: parameters, encoder: JSONParameterEncoder.default, requestModifier: { $0.timeoutInterval = self.timeout })

        request.validate().responseDecodable(of: AppVersionDec.self) { response in
            switch response.result {
            case .success:
                if let url = response.value?.url {
                    latest.url = url
                }
                if let checksum = response.value?.checksum {
                    latest.checksum = checksum
                }
                if let version = response.value?.version {
                    latest.version = version
                }
                if let major = response.value?.major {
                    latest.major = major
                }
                if let error = response.value?.error {
                    latest.error = error
                }
                if let message = response.value?.message {
                    latest.message = message
                }
                if let sessionKey = response.value?.session_key {
                    latest.sessionKey = sessionKey
                }
                if let data = response.value?.data {
                    latest.data = data
                }
                if let manifest = response.value?.manifest {
                    latest.manifest = manifest
                }
            case let .failure(error):
                print("\(CapacitorUpdater.TAG) Error getting Latest", response.value ?? "", error )
                latest.message = "Error getting Latest \(String(describing: response.value))"
                latest.error = "response_error"
            }
            semaphore.signal()
        }
        semaphore.wait()
        return latest
    }

    private func setCurrentBundle(bundle: String) {
        UserDefaults.standard.set(bundle, forKey: self.CAP_SERVER_PATH)
        UserDefaults.standard.synchronize()
        print("\(CapacitorUpdater.TAG) Current bundle set to: \((bundle ).isEmpty ? BundleInfo.ID_BUILTIN : bundle)")
    }

    private var tempDataPath: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("package.tmp")
    }

    private var updateInfo: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("update.dat")
    }
    private var tempData = Data()

    private func verifyChecksum(file: URL, expectedHash: String) -> Bool {
        let actualHash = CryptoCipher.calcChecksum(filePath: file)
        return actualHash == expectedHash
    }

    public func downloadManifest(manifest: [ManifestEntry], version: String, sessionKey: String) throws -> BundleInfo {
        let id = self.randomString(length: 10)
        print("\(CapacitorUpdater.TAG) downloadManifest start \(id)")
        let destFolder = self.getBundleDirectory(id: id)
        let builtinFolder = Bundle.main.bundleURL.appendingPathComponent("public")

        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true, attributes: nil)

        // Create and save BundleInfo before starting the download process
        let bundleInfo = BundleInfo(id: id, version: version, status: BundleStatus.DOWNLOADING, downloaded: Date(), checksum: "")
        self.saveBundleInfo(id: id, bundle: bundleInfo)

        // Notify the start of the download process
        self.notifyDownload(id: id, percent: 0, ignoreMultipleOfTen: true)

        let dispatchGroup = DispatchGroup()
        var downloadError: Error?

        let totalFiles = manifest.count
        var completedFiles = 0

        for entry in manifest {
            guard let fileName = entry.file_name,
                  var fileHash = entry.file_hash,
                  let downloadUrl = entry.download_url else {
                continue
            }

            do {
                fileHash = try CryptoCipher.decryptChecksum(checksum: fileHash, publicKey: self.publicKey, version: version)
            } catch {
                downloadError = error
                print("\(CapacitorUpdater.TAG) CryptoCipher.decryptChecksum error \(id) \(fileName) error: \(error)")
            }

            let fileNameWithoutPath = (fileName as NSString).lastPathComponent
            let cacheFileName = "\(fileHash)_\(fileNameWithoutPath)"
            let cacheFilePath = cacheFolder.appendingPathComponent(cacheFileName)
            let destFilePath = destFolder.appendingPathComponent(fileName)
            let builtinFilePath = builtinFolder.appendingPathComponent(fileName)

            // Create necessary subdirectories in the destination folder
            try FileManager.default.createDirectory(at: destFilePath.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)

            dispatchGroup.enter()

            if FileManager.default.fileExists(atPath: builtinFilePath.path) && verifyChecksum(file: builtinFilePath, expectedHash: fileHash) {
                try FileManager.default.copyItem(at: builtinFilePath, to: destFilePath)
                print("\(CapacitorUpdater.TAG) downloadManifest \(fileName) using builtin file \(id)")
                completedFiles += 1
                self.notifyDownload(id: id, percent: self.calcTotalPercent(percent: Int((Double(completedFiles) / Double(totalFiles)) * 100), min: 10, max: 70))
                dispatchGroup.leave()
            } else if FileManager.default.fileExists(atPath: cacheFilePath.path) && verifyChecksum(file: cacheFilePath, expectedHash: fileHash) {
                try FileManager.default.copyItem(at: cacheFilePath, to: destFilePath)
                print("\(CapacitorUpdater.TAG) downloadManifest \(fileName) copy from cache \(id)")
                completedFiles += 1
                self.notifyDownload(id: id, percent: self.calcTotalPercent(percent: Int((Double(completedFiles) / Double(totalFiles)) * 100), min: 10, max: 70))
                dispatchGroup.leave()
            } else {
                // File not in cache, download, decompress, and save to both cache and destination
                AF.download(downloadUrl).responseData { response in
                    defer { dispatchGroup.leave() }

                    switch response.result {
                    case .success(let data):
                        do {
                            let statusCode = response.response?.statusCode ?? 200
                            if statusCode < 200 || statusCode >= 300 {
                                if let stringData = String(data: data, encoding: .utf8) {
                                    throw NSError(domain: "StatusCodeError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch. Status code (\(statusCode)) invalid. Data: \(stringData)"])
                                } else {
                                    throw NSError(domain: "StatusCodeError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch. Status code (\(statusCode)) invalid"])
                                }
                            }

                            // Add decryption step if public key is set and sessionKey is provided
                            var finalData = data
                            if !self.publicKey.isEmpty && !sessionKey.isEmpty {
                                let tempFile = self.cacheFolder.appendingPathComponent("temp_\(UUID().uuidString)")
                                try finalData.write(to: tempFile)
                                do {
                                    try CryptoCipher.decryptFile(filePath: tempFile, publicKey: self.publicKey, sessionKey: sessionKey, version: version)
                                } catch {
                                    self.sendStats(action: "decrypt_fail", versionName: version)
                                    throw error
                                }
                                // TODO: try and do             self.sendStats(action: "decrypt_fail", versionName: version) if fail
                                finalData = try Data(contentsOf: tempFile)
                                try FileManager.default.removeItem(at: tempFile)
                            }

                            // Decompress the Brotli data
                            guard let decompressedData = self.decompressBrotli(data: finalData, fileName: fileName) else {
                                throw NSError(domain: "BrotliDecompressionError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decompress Brotli data"])
                            }
                            finalData = decompressedData

                            try finalData.write(to: destFilePath)
                            // assume that calcChecksum != null
                            let calculatedChecksum = CryptoCipher.calcChecksum(filePath: destFilePath)
                            if calculatedChecksum != fileHash {
                                throw NSError(domain: "ChecksumError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Computed checksum is not equal to required checksum (\(calculatedChecksum) != \(fileHash))"])
                            }

                            // Save decrypted data to cache and destination
                            try finalData.write(to: cacheFilePath)

                            completedFiles += 1
                            self.notifyDownload(id: id, percent: self.calcTotalPercent(percent: Int((Double(completedFiles) / Double(totalFiles)) * 100), min: 10, max: 70))
                            print("\(CapacitorUpdater.TAG) downloadManifest \(id) \(fileName) downloaded, decompressed\(!self.publicKey.isEmpty && !sessionKey.isEmpty ? ", decrypted" : ""), and cached")
                        } catch {
                            downloadError = error
                            print("\(CapacitorUpdater.TAG) downloadManifest \(id) \(fileName) error: \(error)")
                        }
                    case .failure(let error):
                        print("\(CapacitorUpdater.TAG) downloadManifest \(id) \(fileName) download error: \(error). Debug response: \(response.debugDescription).")
                    }
                }
            }
        }

        dispatchGroup.wait()

        if let error = downloadError {
            // Update bundle status to ERROR if download failed
            let errorBundle = bundleInfo.setStatus(status: BundleStatus.ERROR.localizedString)
            self.saveBundleInfo(id: id, bundle: errorBundle)
            throw error
        }

        // Update bundle status to PENDING after successful download
        let updatedBundle = bundleInfo.setStatus(status: BundleStatus.PENDING.localizedString)
        self.saveBundleInfo(id: id, bundle: updatedBundle)

        print("\(CapacitorUpdater.TAG) downloadManifest done \(id)")
        return updatedBundle
    }

    private func decompressBrotli(data: Data, fileName: String) -> Data? {
        let outputBufferSize = 65536
        var outputBuffer = [UInt8](repeating: 0, count: outputBufferSize)
        var decompressedData = Data()

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        var status = compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI)
        guard status != COMPRESSION_STATUS_ERROR else {
            print("\(CapacitorUpdater.TAG) Unable to initialize the decompression stream. \(fileName)")
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
                        print("\(CapacitorUpdater.TAG) Error: Unable to get base address of input data. \(fileName)")
                        status = COMPRESSION_STATUS_ERROR
                        return
                    }
                }
            }

            if status == COMPRESSION_STATUS_ERROR {
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
                print("\(CapacitorUpdater.TAG) Error during Brotli decompression. \(fileName)")
                // Try to decode as text if mostly ASCII
                if let text = String(data: data, encoding: .utf8) {
                    let asciiCount = text.unicodeScalars.filter { $0.isASCII }.count
                    let totalCount = text.unicodeScalars.count
                    if totalCount > 0 && Double(asciiCount) / Double(totalCount) >= 0.8 {
                        print("\(CapacitorUpdater.TAG) Compressed data as text: \(text)")
                    }
                }
                return nil
            }

            if streamPointer.pointee.dst_size == 0 {
                streamPointer.pointee.dst_ptr = UnsafeMutablePointer<UInt8>(&outputBuffer)
                streamPointer.pointee.dst_size = outputBufferSize
            }

            if input.count == 0 {
                break
            }
        }

        return status == COMPRESSION_STATUS_END ? decompressedData : nil
    }

    public func download(url: URL, version: String, sessionKey: String) throws -> BundleInfo {
        let id: String = self.randomString(length: 10)
        let semaphore = DispatchSemaphore(value: 0)
        if version != getLocalUpdateVersion() {
            cleanDownloadData()
        }
        ensureResumableFilesExist()
        saveDownloadInfo(version)
        var checksum = ""
        var targetSize = -1
        var lastSentProgress = 0
        var totalReceivedBytes: Int64 = loadDownloadProgress() // Retrieving the amount of already downloaded data if exist, defined at 0 otherwise
        let requestHeaders: HTTPHeaders = ["Range": "bytes=\(totalReceivedBytes)-"]
        // Opening connection for streaming the bytes
        if totalReceivedBytes == 0 {
            self.notifyDownload(id: id, percent: 0, ignoreMultipleOfTen: true)
        }
        var mainError: NSError?
        let monitor = ClosureEventMonitor()
        monitor.requestDidCompleteTaskWithError = { (_, _, error) in
            if error != nil {
                print("\(CapacitorUpdater.TAG) Downloading failed - ClosureEventMonitor activated")
                mainError = error as NSError?
            }
        }
        let session = Session(eventMonitors: [monitor])

        var request = session.streamRequest(url, headers: requestHeaders).validate().onHTTPResponse(perform: { response  in
            if let contentLength = response.headers.value(for: "Content-Length") {
                targetSize = (Int(contentLength) ?? -1) + Int(totalReceivedBytes)
            }
        }).responseStream { [weak self] streamResponse in
            guard let self = self else { return }
            switch streamResponse.event {
            case .stream(let result):
                if case .success(let data) = result {
                    self.tempData.append(data)

                    self.savePartialData(startingAt: UInt64(totalReceivedBytes)) // Saving the received data in the package.tmp file
                    totalReceivedBytes += Int64(data.count)

                    let percent = max(10, Int((Double(totalReceivedBytes) / Double(targetSize)) * 70.0))

                    let currentMilestone = (percent / 10) * 10
                    if currentMilestone > lastSentProgress && currentMilestone <= 70 {
                        for milestone in stride(from: lastSentProgress + 10, through: currentMilestone, by: 10) {
                            self.notifyDownload(id: id, percent: milestone, ignoreMultipleOfTen: false)
                        }
                        lastSentProgress = currentMilestone
                    }

                } else {
                    print("\(CapacitorUpdater.TAG) Download failed")
                }

            case .complete:
                print("\(CapacitorUpdater.TAG) Download complete, total received bytes: \(totalReceivedBytes)")
                self.notifyDownload(id: id, percent: 70, ignoreMultipleOfTen: true)
                semaphore.signal()
            }
        }
        self.saveBundleInfo(id: id, bundle: BundleInfo(id: id, version: version, status: BundleStatus.DOWNLOADING, downloaded: Date(), checksum: checksum))
        let reachabilityManager = NetworkReachabilityManager()
        reachabilityManager?.startListening { status in
            switch status {
            case .notReachable:
                // Stop the download request if the network is not reachable
                request.cancel()
                mainError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
                semaphore.signal()
            default:
                break
            }
        }
        semaphore.wait()
        reachabilityManager?.stopListening()

        if mainError != nil {
            print("\(CapacitorUpdater.TAG) Failed to download: \(String(describing: mainError))")
            self.saveBundleInfo(id: id, bundle: BundleInfo(id: id, version: version, status: BundleStatus.ERROR, downloaded: Date(), checksum: checksum))
            throw mainError!
        }

        let finalPath = tempDataPath.deletingLastPathComponent().appendingPathComponent("\(id)")
        do {
            var checksumDecrypted = checksum
            do {
                try CryptoCipher.decryptFile(filePath: tempDataPath, publicKey: self.publicKey, sessionKey: sessionKey, version: version)
            } catch {
                self.sendStats(action: "decrypt_fail", versionName: version)
                throw error
            }
            try FileManager.default.moveItem(at: tempDataPath, to: finalPath)
        } catch {
            print("\(CapacitorUpdater.TAG) Failed decrypt file : \(error)")
            self.saveBundleInfo(id: id, bundle: BundleInfo(id: id, version: version, status: BundleStatus.ERROR, downloaded: Date(), checksum: checksum))
            cleanDownloadData()
            throw error
        }

        do {
            checksum = CryptoCipher.calcChecksum(filePath: finalPath)
            print("\(CapacitorUpdater.TAG) Downloading: 80% (unzipping)")
            try self.saveDownloaded(sourceZip: finalPath, id: id, base: self.libraryDir.appendingPathComponent(self.bundleDirectory), notify: true)

        } catch {
            print("\(CapacitorUpdater.TAG) Failed to unzip file: \(error)")
            self.saveBundleInfo(id: id, bundle: BundleInfo(id: id, version: version, status: BundleStatus.ERROR, downloaded: Date(), checksum: checksum))
            cleanDownloadData()
            // todo: cleanup zip attempts
            throw error
        }

        self.notifyDownload(id: id, percent: 90)
        print("\(CapacitorUpdater.TAG) Downloading: 90% (wrapping up)")
        let info = BundleInfo(id: id, version: version, status: BundleStatus.PENDING, downloaded: Date(), checksum: checksum)
        self.saveBundleInfo(id: id, bundle: info)
        self.cleanDownloadData()
        self.notifyDownload(id: id, percent: 100)
        print("\(CapacitorUpdater.TAG) Downloading: 100% (complete)")
        return info
    }
    private func ensureResumableFilesExist() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: tempDataPath.path) {
            if !fileManager.createFile(atPath: tempDataPath.path, contents: Data()) {
                print("\(CapacitorUpdater.TAG) Cannot ensure that a file at \(tempDataPath.path) exists")
            }
        }

        if !fileManager.fileExists(atPath: updateInfo.path) {
            if !fileManager.createFile(atPath: updateInfo.path, contents: Data()) {
                print("\(CapacitorUpdater.TAG) Cannot ensure that a file at \(updateInfo.path) exists")
            }
        }
    }

    private func cleanDownloadData() {
        // Deleting package.tmp
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: tempDataPath.path) {
            do {
                try fileManager.removeItem(at: tempDataPath)
            } catch {
                print("\(CapacitorUpdater.TAG) Could not delete file at \(tempDataPath): \(error)")
            }
        }
        // Deleting update.dat
        if fileManager.fileExists(atPath: updateInfo.path) {
            do {
                try fileManager.removeItem(at: updateInfo)
            } catch {
                print("\(CapacitorUpdater.TAG) Could not delete file at \(updateInfo): \(error)")
            }
        }
    }

    private func savePartialData(startingAt byteOffset: UInt64) {
        let fileManager = FileManager.default
        do {
            // Check if package.tmp exist
            if !fileManager.fileExists(atPath: tempDataPath.path) {
                try self.tempData.write(to: tempDataPath, options: .atomicWrite)
            } else {
                // If yes, it start writing on it
                let fileHandle = try FileHandle(forWritingTo: tempDataPath)
                fileHandle.seek(toFileOffset: byteOffset) // Moving at the specified position to start writing
                fileHandle.write(self.tempData)
                fileHandle.closeFile()
            }
        } catch {
            print("Failed to write data starting at byte \(byteOffset): \(error)")
        }
        self.tempData.removeAll() // Clearing tempData to avoid writing the same data multiple times
    }

    private func saveDownloadInfo(_ version: String) {
        do {
            try "\(version)".write(to: updateInfo, atomically: true, encoding: .utf8)
        } catch {
            print("\(CapacitorUpdater.TAG) Failed to save progress: \(error)")
        }
    }
    private func getLocalUpdateVersion() -> String { // Return the version that was tried to be downloaded on last download attempt
        if !FileManager.default.fileExists(atPath: updateInfo.path) {
            return "nil"
        }
        guard let versionString = try? String(contentsOf: updateInfo),
              let version = Optional(versionString) else {
            return "nil"
        }
        return version
    }
    private func loadDownloadProgress() -> Int64 {

        let fileManager = FileManager.default
        do {
            let attributes = try fileManager.attributesOfItem(atPath: tempDataPath.path)
            if let fileSize = attributes[.size] as? NSNumber {
                return fileSize.int64Value
            }
        } catch {
            print("\(CapacitorUpdater.TAG) Could not retrieve already downloaded data size : \(error)")
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
                print("\(CapacitorUpdater.TAG) list File : \(dest.path)")
                if dest.exist {
                    for id: String in files {
                        res.append(self.getBundleInfo(id: id))
                    }
                }
                return res
            } catch {
                print("\(CapacitorUpdater.TAG) No version available \(dest.path)")
                return []
            }
        } else {
            guard let regex = try? NSRegularExpression(pattern: "^[0-9A-Za-z]{10}_info$") else {
                print("\(CapacitorUpdater.TAG) Invald regex ?????")
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
            print("\(CapacitorUpdater.TAG) Cannot delete \(id)")
            return false
        }

        // Check if this is the next bundle and prevent deletion if it is
        if let next = self.getNextBundle(),
           !next.isDeleted() &&
            !next.isErrorStatus() &&
            next.getId() == id {
            print("\(CapacitorUpdater.TAG) Cannot delete the next bundle \(id)")
            return false
        }

        let destPersist: URL = libraryDir.appendingPathComponent(bundleDirectory).appendingPathComponent(id)
        do {
            try FileManager.default.removeItem(atPath: destPersist.path)
        } catch {
            print("\(CapacitorUpdater.TAG) Folder \(destPersist.path), not removed.")
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
            self.saveBundleInfo(id: id, bundle: deleted.setStatus(status: BundleStatus.DELETED.localizedString))
        }
        print("\(CapacitorUpdater.TAG) bundle delete \(deleted.getVersionName())")
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

    private func bundleExists(id: String) -> Bool {
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
            print("\(CapacitorUpdater.TAG) Folder at bundle path does not exist. Triggering reset.")
            self.reset()
        }
    }

    public func reset() {
        self.reset(isInternal: false)
    }

    public func reset(isInternal: Bool) {
        print("\(CapacitorUpdater.TAG) reset: \(isInternal)")
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
        let fallback: BundleInfo = self.getFallbackBundle()
        print("\(CapacitorUpdater.TAG) Fallback bundle is: \(fallback.toString())")
        print("\(CapacitorUpdater.TAG) Version successfully loaded: \(bundle.toString())")
        if autoDeletePrevious && !fallback.isBuiltin() && fallback.getId() != bundle.getId() {
            let res = self.delete(id: fallback.getId())
            if res {
                print("\(CapacitorUpdater.TAG) Deleted previous bundle: \(fallback.toString())")
            } else {
                print("\(CapacitorUpdater.TAG) Failed to delete previous bundle: \(fallback.toString())")
            }
        }
        self.setFallbackBundle(fallback: bundle)
    }

    public func setError(bundle: BundleInfo) {
        self.setBundleStatus(id: bundle.getId(), status: BundleStatus.ERROR)
    }

    func unsetChannel() -> SetChannel {
        let setChannel: SetChannel = SetChannel()
        if (self.channelUrl ).isEmpty {
            print("\(CapacitorUpdater.TAG) Channel URL is not set")
            setChannel.message = "Channel URL is not set"
            setChannel.error = "missing_config"
            return setChannel
        }
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        let parameters: InfoObject = self.createInfoObject()

        let request = AF.request(self.channelUrl, method: .delete, parameters: parameters, encoder: JSONParameterEncoder.default, requestModifier: { $0.timeoutInterval = self.timeout })

        request.validate().responseDecodable(of: SetChannelDec.self) { response in
            switch response.result {
            case .success:
                if let status = response.value?.status {
                    setChannel.status = status
                }
                if let error = response.value?.error {
                    setChannel.error = error
                }
                if let message = response.value?.message {
                    setChannel.message = message
                }
            case let .failure(error):
                print("\(CapacitorUpdater.TAG) Error unset Channel", response.value ?? "", error)
                setChannel.message = "Error unset Channel \(String(describing: response.value))"
                setChannel.error = "response_error"
            }
            semaphore.signal()
        }
        semaphore.wait()
        return setChannel
    }

    func setChannel(channel: String) -> SetChannel {
        let setChannel: SetChannel = SetChannel()
        if (self.channelUrl ).isEmpty {
            print("\(CapacitorUpdater.TAG) Channel URL is not set")
            setChannel.message = "Channel URL is not set"
            setChannel.error = "missing_config"
            return setChannel
        }
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        var parameters: InfoObject = self.createInfoObject()
        parameters.channel = channel

        let request = AF.request(self.channelUrl, method: .post, parameters: parameters, encoder: JSONParameterEncoder.default, requestModifier: { $0.timeoutInterval = self.timeout })

        request.validate().responseDecodable(of: SetChannelDec.self) { response in
            switch response.result {
            case .success:
                if let status = response.value?.status {
                    setChannel.status = status
                }
                if let error = response.value?.error {
                    setChannel.error = error
                }
                if let message = response.value?.message {
                    setChannel.message = message
                }
            case let .failure(error):
                print("\(CapacitorUpdater.TAG) Error set Channel", response.value ?? "", error)
                setChannel.message = "Error set Channel \(String(describing: response.value))"
                setChannel.error = "response_error"
            }
            semaphore.signal()
        }
        semaphore.wait()
        return setChannel
    }

    func getChannel() -> GetChannel {
        let getChannel: GetChannel = GetChannel()
        if (self.channelUrl ).isEmpty {
            print("\(CapacitorUpdater.TAG) Channel URL is not set")
            getChannel.message = "Channel URL is not set"
            getChannel.error = "missing_config"
            return getChannel
        }
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        let parameters: InfoObject = self.createInfoObject()
        let request = AF.request(self.channelUrl, method: .put, parameters: parameters, encoder: JSONParameterEncoder.default, requestModifier: { $0.timeoutInterval = self.timeout })

        request.validate().responseDecodable(of: GetChannelDec.self) { response in
            defer {
                semaphore.signal()
            }
            switch response.result {
            case .success:
                if let status = response.value?.status {
                    getChannel.status = status
                }
                if let error = response.value?.error {
                    getChannel.error = error
                }
                if let message = response.value?.message {
                    getChannel.message = message
                }
                if let channel = response.value?.channel {
                    getChannel.channel = channel
                }
                if let allowSet = response.value?.allowSet {
                    getChannel.allowSet = allowSet
                }
            case let .failure(error):
                if let data = response.data, let bodyString = String(data: data, encoding: .utf8) {
                    if bodyString.contains("channel_not_found") && response.response?.statusCode == 400 && !self.defaultChannel.isEmpty {
                        getChannel.channel = self.defaultChannel
                        getChannel.status = "default"
                        return
                    }
                }

                print("\(CapacitorUpdater.TAG) Error get Channel", response.value ?? "", error)
                getChannel.message = "Error get Channel \(String(describing: response.value)))"
                getChannel.error = "response_error"
            }
        }
        semaphore.wait()
        return getChannel
    }

    private let operationQueue = OperationQueue()

    func sendStats(action: String, versionName: String? = nil, oldVersionName: String? = "") {
        guard !statsUrl.isEmpty else {
            return
        }
        operationQueue.maxConcurrentOperationCount = 1

        let versionName = versionName ?? getCurrentBundle().getVersionName()

        var parameters = createInfoObject()
        parameters.action = action
        parameters.version_name = versionName
        parameters.old_version_name = oldVersionName ?? ""

        let operation = BlockOperation {
            let semaphore = DispatchSemaphore(value: 0)
            AF.request(
                self.statsUrl,
                method: .post,
                parameters: parameters,
                encoder: JSONParameterEncoder.default,
                requestModifier: { $0.timeoutInterval = self.timeout }
            ).responseData { response in
                switch response.result {
                case .success:
                    print("\(CapacitorUpdater.TAG) Stats sent for \(action), version \(versionName)")
                case let .failure(error):
                    print("\(CapacitorUpdater.TAG) Error sending stats: ", response.value ?? "", error.localizedDescription)
                }
                semaphore.signal()
            }
            semaphore.signal()
        }
        operationQueue.addOperation(operation)

    }

    public func getBundleInfo(id: String?) -> BundleInfo {
        var trueId = BundleInfo.VERSION_UNKNOWN
        if id != nil {
            trueId = id!
        }
        // print("\(CapacitorUpdater.TAG) Getting info for bundle [\(trueId)]")
        let result: BundleInfo
        if BundleInfo.ID_BUILTIN == trueId {
            result = BundleInfo(id: trueId, version: "", status: BundleStatus.SUCCESS, checksum: "")
        } else if BundleInfo.VERSION_UNKNOWN == trueId {
            result = BundleInfo(id: trueId, version: "", status: BundleStatus.ERROR, checksum: "")
        } else {
            do {
                result = try UserDefaults.standard.getObj(forKey: "\(trueId)\(self.INFO_SUFFIX)", castTo: BundleInfo.self)
            } catch {
                print("\(CapacitorUpdater.TAG) Failed to parse info for bundle [\(trueId)]", error.localizedDescription)
                result = BundleInfo(id: trueId, version: "", status: BundleStatus.PENDING, checksum: "")
            }
        }
        // print("\(CapacitorUpdater.TAG) Returning info bundle [\(result.toString())]")
        return result
    }

    public func getBundleInfoByVersionName(version: String) -> BundleInfo? {
        let installed: [BundleInfo] = self.list()
        for i in installed {
            if i.getVersionName() == version {
                return i
            }
        }
        return nil
    }

    private func removeBundleInfo(id: String) {
        self.saveBundleInfo(id: id, bundle: nil)
    }

    public func saveBundleInfo(id: String, bundle: BundleInfo?) {
        if bundle != nil && (bundle!.isBuiltin() || bundle!.isUnknown()) {
            print("\(CapacitorUpdater.TAG) Not saving info for bundle [\(id)]", bundle?.toString() ?? "")
            return
        }
        if bundle == nil {
            print("\(CapacitorUpdater.TAG) Removing info for bundle [\(id)]")
            UserDefaults.standard.removeObject(forKey: "\(id)\(self.INFO_SUFFIX)")
        } else {
            let update = bundle!.setId(id: id)
            print("\(CapacitorUpdater.TAG) Storing info for bundle [\(id)]", update.toString())
            do {
                try UserDefaults.standard.setObj(update, forKey: "\(id)\(self.INFO_SUFFIX)")
            } catch {
                print("\(CapacitorUpdater.TAG) Failed to save info for bundle [\(id)]", error.localizedDescription)
            }
        }
        UserDefaults.standard.synchronize()
    }

    private func setBundleStatus(id: String, status: BundleStatus) {
        print("\(CapacitorUpdater.TAG) Setting status for bundle [\(id)] to \(status)")
        let info = self.getBundleInfo(id: id)
        self.saveBundleInfo(id: id, bundle: info.setStatus(status: status.localizedString))
    }

    public func getCurrentBundle() -> BundleInfo {
        return self.getBundleInfo(id: self.getCurrentBundleId())
    }

    public func getCurrentBundleId() -> String {
        guard let bundlePath: String = UserDefaults.standard.string(forKey: self.CAP_SERVER_PATH) else {
            return BundleInfo.ID_BUILTIN
        }
        if (bundlePath).isEmpty {
            return BundleInfo.ID_BUILTIN
        }
        let bundleID: String = bundlePath.components(separatedBy: "/").last ?? bundlePath
        return bundleID
    }

    public func isUsingBuiltin() -> Bool {
        return (UserDefaults.standard.string(forKey: self.CAP_SERVER_PATH) ?? "") == self.DEFAULT_FOLDER
    }

    public func getFallbackBundle() -> BundleInfo {
        let id: String = UserDefaults.standard.string(forKey: self.FALLBACK_VERSION) ?? BundleInfo.ID_BUILTIN
        return self.getBundleInfo(id: id)
    }

    private func setFallbackBundle(fallback: BundleInfo?) {
        UserDefaults.standard.set(fallback == nil ? BundleInfo.ID_BUILTIN : fallback!.getId(), forKey: self.FALLBACK_VERSION)
        UserDefaults.standard.synchronize()
    }

    public func getNextBundle() -> BundleInfo? {
        let id: String? = UserDefaults.standard.string(forKey: self.NEXT_VERSION)
        return self.getBundleInfo(id: id)
    }

    public func setNextBundle(next: String?) -> Bool {
        guard let nextId: String = next else {
            UserDefaults.standard.removeObject(forKey: self.NEXT_VERSION)
            UserDefaults.standard.synchronize()
            return false
        }
        let newBundle: BundleInfo = self.getBundleInfo(id: nextId)
        if !newBundle.isBuiltin() && !self.bundleExists(id: nextId) {
            return false
        }
        UserDefaults.standard.set(nextId, forKey: self.NEXT_VERSION)
        UserDefaults.standard.synchronize()
        self.setBundleStatus(id: nextId, status: BundleStatus.PENDING)
        return true
    }
}
