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

@objc public class CapgoUpdater: NSObject {
    private var logger: Logger!

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

    public func setLogger(_ logger: Logger) {
        self.logger = logger
    }

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
                logger.error("Cannot createDirectory \(source.path)")
                throw CustomError.cannotCreateDirectory
            }
        }
    }

    private func deleteFolder(source: URL) throws {
        do {
            try FileManager.default.removeItem(atPath: source.path)
        } catch {
            logger.error("File not removed. \(source.path)")
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
            logger.error("File not moved. source: \(source.path) dest: \(dest.path)")
            throw CustomError.cannotUnflat
        }
    }

    private func unzipProgressHandler(entry: String, zipInfo: unz_file_info, entryNumber: Int, total: Int, destUnZip: URL, id: String, unzipError: inout NSError?) {
        if entry.contains("\\") {
            logger.error("unzip: Windows path is not supported, please use unix path as required by zip RFC: \(entry)")
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
        logger.info("Auto-update parameters: \(parameters)")
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
                self.logger.error("Error getting Latest \(response.value.debugDescription) \(error)")
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
        logger.info("Current bundle set to: \((bundle ).isEmpty ? BundleInfo.ID_BUILTIN : bundle)")
    }

    private var tempDataPath: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("package.tmp")
    }

    private var updateInfo: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("update.dat")
    }
    private var tempData = Data()

    private func verifyChecksum(file: URL, expectedHash: String) -> Bool {
        let actualHash = CryptoCipherV2.calcChecksum(filePath: file)
        return actualHash == expectedHash
    }

    public func downloadManifest(manifest: [ManifestEntry], version: String, sessionKey: String) throws -> BundleInfo {
        let id = self.randomString(length: 10)
        logger.info("downloadManifest start \(id)")
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

            if !self.publicKey.isEmpty && !sessionKey.isEmpty {
                do {
                    fileHash = try CryptoCipherV2.decryptChecksum(checksum: fileHash, publicKey: self.publicKey)
                } catch {
                    downloadError = error
                    logger.error("CryptoCipherV2.decryptChecksum error \(id) \(fileName) error: \(error)")
                }
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
                logger.info("downloadManifest \(fileName) using builtin file \(id)")
                completedFiles += 1
                self.notifyDownload(id: id, percent: self.calcTotalPercent(percent: Int((Double(completedFiles) / Double(totalFiles)) * 100), min: 10, max: 70))
                dispatchGroup.leave()
            } else if FileManager.default.fileExists(atPath: cacheFilePath.path) && verifyChecksum(file: cacheFilePath, expectedHash: fileHash) {
                try FileManager.default.copyItem(at: cacheFilePath, to: destFilePath)
                logger.info("downloadManifest \(fileName) copy from cache \(id)")
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
                                    throw NSError(domain: "StatusCodeError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch. Status code (\(statusCode)) invalid. Data: \(stringData) for file \(fileName) at url \(downloadUrl)"])
                                } else {
                                    throw NSError(domain: "StatusCodeError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch. Status code (\(statusCode)) invalid for file \(fileName) at url \(downloadUrl)"])
                                }
                            }

                            // Add decryption step if public key is set and sessionKey is provided
                            var finalData = data
                            if !self.publicKey.isEmpty && !sessionKey.isEmpty {
                                let tempFile = self.cacheFolder.appendingPathComponent("temp_\(UUID().uuidString)")
                                try finalData.write(to: tempFile)
                                do {
                                    try CryptoCipherV2.decryptFile(filePath: tempFile, publicKey: self.publicKey, sessionKey: sessionKey, version: version)
                                } catch {
                                    self.sendStats(action: "decrypt_fail", versionName: version)
                                    throw error
                                }
                                // TODO: try and do             self.sendStats(action: "decrypt_fail", versionName: version) if fail
                                finalData = try Data(contentsOf: tempFile)
                                try FileManager.default.removeItem(at: tempFile)
                            }

                            // Check if file has .br extension for Brotli decompression
                            let isBrotli = fileName.hasSuffix(".br")
                            let finalFileName = isBrotli ? String(fileName.dropLast(3)) : fileName
                            let destFilePath = destFolder.appendingPathComponent(finalFileName)

                            if isBrotli {
                                // Decompress the Brotli data
                                guard let decompressedData = self.decompressBrotli(data: finalData, fileName: fileName) else {
                                    throw NSError(domain: "BrotliDecompressionError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decompress Brotli data for file \(fileName) at url \(downloadUrl)"])
                                }
                                finalData = decompressedData
                            }

                            try finalData.write(to: destFilePath)
                            if !self.publicKey.isEmpty && !sessionKey.isEmpty {
                                // assume that calcChecksum != null
                                let calculatedChecksum = CryptoCipherV2.calcChecksum(filePath: destFilePath)
                                if calculatedChecksum != fileHash {
                                    throw NSError(domain: "ChecksumError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Computed checksum is not equal to required checksum (\(calculatedChecksum) != \(fileHash)) for file \(fileName) at url \(downloadUrl)"])
                                }
                            }

                            // Save decrypted data to cache and destination
                            try finalData.write(to: cacheFilePath)

                            completedFiles += 1
                            self.notifyDownload(id: id, percent: self.calcTotalPercent(percent: Int((Double(completedFiles) / Double(totalFiles)) * 100), min: 10, max: 70))
                            self.logger.info("downloadManifest \(id) \(fileName) downloaded\(isBrotli ? ", decompressed" : "")\(!self.publicKey.isEmpty && !sessionKey.isEmpty ? ", decrypted" : ""), and cached")
                        } catch {
                            downloadError = error
                            self.logger.error("downloadManifest \(id) \(fileName) error: \(error.localizedDescription)")
                        }
                    case .failure(let error):
                        self.logger.error("downloadManifest \(id) \(fileName) download error: \(error.localizedDescription). Debug response: \(response.debugDescription).")
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

        logger.info("downloadManifest done \(id)")
        return updatedBundle
    }

    private func decompressBrotli(data: Data, fileName: String) -> Data? {
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
            let maxBytes = min(32, data.count)
            let hexDump = data.prefix(maxBytes).map { String(format: "%02x", $0) }.joined(separator: " ")
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
            logger.error("Error: Failed to initialize Brotli stream for \(fileName). Status: \(status)")
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
                        logger.error("Error: Failed to get base address for \(fileName)")
                        status = COMPRESSION_STATUS_ERROR
                        return
                    }
                }
            }

            if status == COMPRESSION_STATUS_ERROR {
                let maxBytes = min(32, data.count)
                let hexDump = data.prefix(maxBytes).map { String(format: "%02x", $0) }.joined(separator: " ")
                logger.error("Error: Brotli decompression failed for \(fileName). First \(maxBytes) bytes: \(hexDump)")
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
                logger.error("Error: Brotli process failed for \(fileName). Status: \(status)")
                if let text = String(data: data, encoding: .utf8) {
                    let asciiCount = text.unicodeScalars.filter { $0.isASCII }.count
                    let totalCount = text.unicodeScalars.count
                    if totalCount > 0 && Double(asciiCount) / Double(totalCount) >= 0.8 {
                        logger.error("Error: Input appears to be plain text: \(text)")
                    }
                }

                let maxBytes = min(32, data.count)
                let hexDump = data.prefix(maxBytes).map { String(format: "%02x", $0) }.joined(separator: " ")
                logger.error("Error: Raw data (\(fileName)): \(hexDump)")

                return nil
            }

            if streamPointer.pointee.dst_size == 0 {
                streamPointer.pointee.dst_ptr = UnsafeMutablePointer<UInt8>(&outputBuffer)
                streamPointer.pointee.dst_size = outputBufferSize
            }

            if input.count == 0 {
                logger.error("Error: Zero input size for \(fileName)")
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
                self.logger.error("Downloading failed - ClosureEventMonitor activated")
                mainError = error as NSError?
            }
        }
        let session = Session(eventMonitors: [monitor])

        let request = session.streamRequest(url, headers: requestHeaders).validate().onHTTPResponse(perform: { response  in
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
                    self.logger.error("Download failed")
                }

            case .complete:
                self.logger.info("Download complete, total received bytes: \(totalReceivedBytes)")
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
            logger.error("Failed to download: \(String(describing: mainError))")
            self.saveBundleInfo(id: id, bundle: BundleInfo(id: id, version: version, status: BundleStatus.ERROR, downloaded: Date(), checksum: checksum))
            throw mainError!
        }

        let finalPath = tempDataPath.deletingLastPathComponent().appendingPathComponent("\(id)")
        do {
            try CryptoCipherV2.decryptFile(filePath: tempDataPath, publicKey: self.publicKey, sessionKey: sessionKey, version: version)
            try FileManager.default.moveItem(at: tempDataPath, to: finalPath)
        } catch {
            logger.error("Failed decrypt file : \(error)")
            self.saveBundleInfo(id: id, bundle: BundleInfo(id: id, version: version, status: BundleStatus.ERROR, downloaded: Date(), checksum: checksum))
            cleanDownloadData()
            throw error
        }

        do {
            checksum = CryptoCipherV2.calcChecksum(filePath: finalPath)
            logger.info("Downloading: 80% (unzipping)")
            try self.saveDownloaded(sourceZip: finalPath, id: id, base: self.libraryDir.appendingPathComponent(self.bundleDirectory), notify: true)

        } catch {
            logger.error("Failed to unzip file: \(error)")
            self.saveBundleInfo(id: id, bundle: BundleInfo(id: id, version: version, status: BundleStatus.ERROR, downloaded: Date(), checksum: checksum))
            cleanDownloadData()
            // todo: cleanup zip attempts
            throw error
        }

        self.notifyDownload(id: id, percent: 90)
        logger.info("Downloading: 90% (wrapping up)")
        let info = BundleInfo(id: id, version: version, status: BundleStatus.PENDING, downloaded: Date(), checksum: checksum)
        self.saveBundleInfo(id: id, bundle: info)
        self.cleanDownloadData()
        self.notifyDownload(id: id, percent: 100)
        logger.info("Downloading: 100% (complete)")
        return info
    }
    private func ensureResumableFilesExist() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: tempDataPath.path) {
            if !fileManager.createFile(atPath: tempDataPath.path, contents: Data()) {
                logger.error("Cannot ensure that a file at \(tempDataPath.path) exists")
            }
        }

        if !fileManager.fileExists(atPath: updateInfo.path) {
            if !fileManager.createFile(atPath: updateInfo.path, contents: Data()) {
                logger.error("Cannot ensure that a file at \(updateInfo.path) exists")
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
                logger.error("Could not delete file at \(tempDataPath): \(error)")
            }
        }
        // Deleting update.dat
        if fileManager.fileExists(atPath: updateInfo.path) {
            do {
                try fileManager.removeItem(at: updateInfo)
            } catch {
                logger.error("Could not delete file at \(updateInfo): \(error)")
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
            logger.error("Failed to write data starting at byte \(byteOffset): \(error)")
        }
        self.tempData.removeAll() // Clearing tempData to avoid writing the same data multiple times
    }

    private func saveDownloadInfo(_ version: String) {
        do {
            try "\(version)".write(to: updateInfo, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to save progress: \(error)")
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
            logger.error("Could not retrieve already downloaded data size : \(error)")
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
            logger.info("Cannot delete \(id)")
            return false
        }

        // Check if this is the next bundle and prevent deletion if it is
        if let next = self.getNextBundle(),
           !next.isDeleted() &&
            !next.isErrorStatus() &&
            next.getId() == id {
            logger.info("Cannot delete the next bundle \(id)")
            return false
        }

        let destPersist: URL = libraryDir.appendingPathComponent(bundleDirectory).appendingPathComponent(id)
        do {
            try FileManager.default.removeItem(atPath: destPersist.path)
        } catch {
            logger.error("Folder \(destPersist.path), not removed.")
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
        logger.info("bundle delete \(deleted.getVersionName())")
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
        let fallback: BundleInfo = self.getFallbackBundle()
        logger.info("Fallback bundle is: \(fallback.toString())")
        logger.info("Version successfully loaded: \(bundle.toString())")
        if autoDeletePrevious && !fallback.isBuiltin() && fallback.getId() != bundle.getId() {
            let res = self.delete(id: fallback.getId())
            if res {
                logger.info("Deleted previous bundle: \(fallback.toString())")
            } else {
                logger.error("Failed to delete previous bundle: \(fallback.toString())")
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
            logger.error("Channel URL is not set")
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
                if let responseValue = response.value {
                    if let error = responseValue.error {
                        setChannel.error = error
                    } else {
                        setChannel.status = responseValue.status ?? ""
                        setChannel.message = responseValue.message ?? ""
                    }
                }
            case let .failure(error):
                self.logger.error("Error unset Channel \(error)")
                setChannel.error = "Request failed: \(error.localizedDescription)"
            }
            semaphore.signal()
        }
        semaphore.wait()
        return setChannel
    }

    func setChannel(channel: String) -> SetChannel {
        let setChannel: SetChannel = SetChannel()
        if (self.channelUrl ).isEmpty {
            logger.error("Channel URL is not set")
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
                if let responseValue = response.value {
                    if let error = responseValue.error {
                        setChannel.error = error
                    } else {
                        setChannel.status = responseValue.status ?? ""
                        setChannel.message = responseValue.message ?? ""
                    }
                }
            case let .failure(error):
                self.logger.error("Error set Channel \(error)")
                setChannel.error = "Request failed: \(error.localizedDescription)"
            }
            semaphore.signal()
        }
        semaphore.wait()
        return setChannel
    }

    func getChannel() -> GetChannel {
        let getChannel: GetChannel = GetChannel()
        if (self.channelUrl ).isEmpty {
            logger.error("Channel URL is not set")
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
                if let responseValue = response.value {
                    if let error = responseValue.error {
                        getChannel.error = error
                    } else {
                        getChannel.status = responseValue.status ?? ""
                        getChannel.message = responseValue.message ?? ""
                        getChannel.channel = responseValue.channel ?? ""
                        getChannel.allowSet = responseValue.allowSet ?? true
                    }
                }
            case let .failure(error):
                if let data = response.data, let bodyString = String(data: data, encoding: .utf8) {
                    if bodyString.contains("channel_not_found") && response.response?.statusCode == 400 && !self.defaultChannel.isEmpty {
                        getChannel.channel = self.defaultChannel
                        getChannel.status = "default"
                        return
                    }
                }

                self.logger.error("Error get Channel \(error)")
                getChannel.error = "Request failed: \(error.localizedDescription)"
            }
        }
        semaphore.wait()
        return getChannel
    }

    func listChannels() -> ListChannels {
        let listChannels: ListChannels = ListChannels()
        if (self.channelUrl).isEmpty {
            logger.error("Channel URL is not set")
            listChannels.error = "Channel URL is not set"
            return listChannels
        }

        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)

        // Auto-detect values
        let appId = self.appId
        let platform = "ios"
        let isEmulator = self.isEmulator()
        let isProd = self.isProd()

        // Create query parameters
        var urlComponents = URLComponents(string: self.channelUrl)
        urlComponents?.queryItems = [
            URLQueryItem(name: "app_id", value: appId),
            URLQueryItem(name: "platform", value: platform),
            URLQueryItem(name: "is_emulator", value: String(isEmulator)),
            URLQueryItem(name: "is_prod", value: String(isProd))
        ]

        guard let url = urlComponents?.url else {
            logger.error("Invalid channel URL")
            listChannels.error = "Invalid channel URL"
            return listChannels
        }

        let request = AF.request(url, method: .get, requestModifier: { $0.timeoutInterval = self.timeout })

        request.validate().responseDecodable(of: ListChannelsDec.self) { response in
            defer {
                semaphore.signal()
            }
            switch response.result {
            case .success:
                if let responseValue = response.value {
                    // Check for server-side errors
                    if let error = responseValue.error {
                        listChannels.error = error
                        return
                    }

                    // Backend returns direct array, so channels should be populated by our custom decoder
                    if let channels = responseValue.channels {
                        listChannels.channels = channels.map { channel in
                            var channelDict: [String: Any] = [:]
                            channelDict["id"] = channel.id ?? ""
                            channelDict["name"] = channel.name ?? ""
                            channelDict["public"] = channel.public ?? false
                            channelDict["allow_self_set"] = channel.allow_self_set ?? false
                            return channelDict
                        }
                    }
                }
            case let .failure(error):
                self.logger.error("Error list channels \(error)")
                listChannels.error = "Request failed: \(error.localizedDescription)"
            }
        }
        semaphore.wait()
        return listChannels
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
                    self.logger.info("Stats sent for \(action), version \(versionName)")
                case let .failure(error):
                    self.logger.error("Error sending stats: \(response.value?.debugDescription ?? "") \(error.localizedDescription)")
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
        let result: BundleInfo
        if BundleInfo.ID_BUILTIN == trueId {
            result = BundleInfo(id: trueId, version: "", status: BundleStatus.SUCCESS, checksum: "")
        } else if BundleInfo.VERSION_UNKNOWN == trueId {
            result = BundleInfo(id: trueId, version: "", status: BundleStatus.ERROR, checksum: "")
        } else {
            do {
                result = try UserDefaults.standard.getObj(forKey: "\(trueId)\(self.INFO_SUFFIX)", castTo: BundleInfo.self)
            } catch {
                logger.error("Failed to parse info for bundle [\(trueId)] \(error.localizedDescription)")
                result = BundleInfo(id: trueId, version: "", status: BundleStatus.PENDING, checksum: "")
            }
        }
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
            logger.info("Not saving info for bundle [\(id)] \(bundle?.toString() ?? "")")
            return
        }
        if bundle == nil {
            logger.info("Removing info for bundle [\(id)]")
            UserDefaults.standard.removeObject(forKey: "\(id)\(self.INFO_SUFFIX)")
        } else {
            let update = bundle!.setId(id: id)
            logger.info("Storing info for bundle [\(id)] \(update.toString())")
            do {
                try UserDefaults.standard.setObj(update, forKey: "\(id)\(self.INFO_SUFFIX)")
            } catch {
                logger.error("Failed to save info for bundle [\(id)] \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.synchronize()
    }

    private func setBundleStatus(id: String, status: BundleStatus) {
        logger.info("Setting status for bundle [\(id)] to \(status)")
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
