/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import SSZipArchive
import Alamofire
import zlib
import GZIP


extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
    var exist: Bool {
        return FileManager().fileExists(atPath: self.path)
    }
}
struct SetChannelDec: Decodable {
    let status: String?
    let error: String?
    let message: String?
}
public class SetChannel: NSObject {
    var status: String = ""
    var error: String = ""
    var message: String = ""
}
extension SetChannel {
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [String: Any]()
        let otherSelf: Mirror = Mirror(reflecting: self)
        for child: Mirror.Child in otherSelf.children {
            if let key: String = child.label {
                dict[key] = child.value
            }
        }
        return dict
    }
}
struct GetChannelDec: Decodable {
    let channel: String?
    let status: String?
    let error: String?
    let message: String?
    let allowSet: Bool?
}
public class GetChannel: NSObject {
    var channel: String = ""
    var status: String = ""
    var error: String = ""
    var message: String = ""
    var allowSet: Bool = true
}
extension GetChannel {
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [String: Any]()
        let otherSelf: Mirror = Mirror(reflecting: self)
        for child: Mirror.Child in otherSelf.children {
            if let key: String = child.label {
                dict[key] = child.value
            }
        }
        return dict
    }
}
struct InfoObject: Codable {
    let platform: String?
    let device_id: String?
    let app_id: String?
    let custom_id: String?
    let version_build: String?
    let version_code: String?
    let version_os: String?
    let version_name: String?
    let plugin_version: String?
    let is_emulator: Bool?
    let is_prod: Bool?
    var action: String?
    var channel: String?
    var defaultChannel: String?
}
public struct DownloadManifestEntry: Decodable {
    let file_name: String
    let file_hash: String
    let download_url: String
}
struct AppVersionDec: Decodable {
    let version: String?
    let checksum: String?
    let url: String?
    let manifest: [DownloadManifestEntry]?
    let message: String?
    let error: String?
    let session_key: String?
    let major: Bool?
    let data: [String: String]?
}
public class AppVersion: NSObject {
    var version: String = ""
    var manifest: [DownloadManifestEntry]?
    var message: String?
    var error: String?
    var sessionKey: String?
    var major: Bool?
    var data: [String: String]?
}

extension AppVersion {
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [String: Any]()
        let otherSelf: Mirror = Mirror(reflecting: self)
        for child: Mirror.Child in otherSelf.children {
            if let key: String = child.label {
                dict[key] = child.value
            }
        }
        return dict
    }
}

extension OperatingSystemVersion {
    func getFullVersion(separator: String = ".") -> String {
        return "\(majorVersion)\(separator)\(minorVersion)\(separator)\(patchVersion)"
    }
}
extension Bundle {
    var versionName: String? {
        return infoDictionary?["CFBundleShortVersionString"] as? String
    }
    var versionCode: String? {
        return infoDictionary?["CFBundleVersion"] as? String
    }
}

extension ISO8601DateFormatter {
    convenience init(_ formatOptions: Options) {
        self.init()
        self.formatOptions = formatOptions
    }
}
extension Formatter {
    static let iso8601withFractionalSeconds: ISO8601DateFormatter = ISO8601DateFormatter([.withInternetDateTime, .withFractionalSeconds])
}
extension Date {
    var iso8601withFractionalSeconds: String { return Formatter.iso8601withFractionalSeconds.string(from: self) }
}
extension String {

    var fileURL: URL {
        return URL(fileURLWithPath: self)
    }

    var lastPathComponent: String {
        get {
            return fileURL.lastPathComponent
        }
    }
    var iso8601withFractionalSeconds: Date? {
        return Formatter.iso8601withFractionalSeconds.date(from: self)
    }
    func trim(using characterSet: CharacterSet = .whitespacesAndNewlines) -> String {
        return trimmingCharacters(in: characterSet)
    }
}

enum CustomError: Error {
    // Throw when an unzip fail
    case cannotUnzip
    case cannotWrite
    case cannotDecode
    case cannotUnflat
    case cannotCreateDirectory
    case cannotDeleteDirectory

    // Throw in all other cases
    case unexpected(code: Int)
}

extension CustomError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cannotUnzip:
            return NSLocalizedString(
                "The file cannot be unzip",
                comment: "Invalid zip"
            )
        case .cannotCreateDirectory:
            return NSLocalizedString(
                "The folder cannot be created",
                comment: "Invalid folder"
            )
        case .cannotDeleteDirectory:
            return NSLocalizedString(
                "The folder cannot be deleted",
                comment: "Invalid folder"
            )
        case .cannotUnflat:
            return NSLocalizedString(
                "The file cannot be unflat",
                comment: "Invalid folder"
            )
        case .unexpected:
            return NSLocalizedString(
                "An unexpected error occurred.",
                comment: "Unexpected Error"
            )
        case .cannotDecode:
            return NSLocalizedString(
                "Decoding the zip failed with this key",
                comment: "Invalid private key"
            )
        case .cannotWrite:
            return NSLocalizedString(
                "Cannot write to the destination",
                comment: "Invalid destination"
            )
        }
    }
}


@objc public class CapacitorUpdater: NSObject {

    private let versionCode: String = Bundle.main.versionCode ?? ""
    private let versionOs = UIDevice.current.systemVersion
    private let documentsDir: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    private let libraryDir: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
    private let bundleDirectoryHot: String = "versions"
    private let DEFAULT_FOLDER: String = ""
    private let bundleDirectory: String = "NoCloud/ionic_built_snapshots"
    private let INFO_SUFFIX: String = "_info"
    private let FALLBACK_VERSION: String = "pastVersion"
    private let NEXT_VERSION: String = "nextVersion"

    public let TAG: String = "✨  Capacitor-updater:"
    public let CAP_SERVER_PATH: String = "capgo_serverBasePath"
    public var versionBuild: String = ""
    public var customId: String = ""
    public var PLUGIN_VERSION: String = ""
    public var timeout: Double = 20
    public var statsUrl: String = ""
    public var channelUrl: String = ""
    public var defaultChannel: String = ""
    public var appId: String = ""
    public var deviceID = UIDevice.current.identifierForVendor?.uuidString ?? ""
    public var privateKey: String = ""
    public var manifestStorage = ManifestStorage()


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

    private static func prepareFolder(source: URL) throws {
        if !FileManager.default.fileExists(atPath: source.path) {
            do {
                try FileManager.default.createDirectory(atPath: source.path, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("✨  Capacitor-updater: Cannot createDirectory \(source.path)")
                throw CustomError.cannotCreateDirectory
            }
        }
    }

    private func deleteFolder(source: URL) throws {
        do {
            try FileManager.default.removeItem(atPath: source.path)
        } catch {
            print("\(self.TAG) File not removed. \(source.path)")
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
            print("\(self.TAG) File not moved. source: \(source.path) dest: \(dest.path)")
            throw CustomError.cannotUnflat
        }
    }

    private func getChecksum(filePath: URL) -> String {
        let bufferSize = 1024 * 1024 * 5 // 5 MB
        var checksum = uLong(0)

        do {
            let fileHandle = try FileHandle(forReadingFrom: filePath)
            defer {
                fileHandle.closeFile()
            }

            while autoreleasepool(invoking: {
                let fileData = fileHandle.readData(ofLength: bufferSize)
                if fileData.count > 0 {
                    checksum = fileData.withUnsafeBytes {
                        crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt(fileData.count))
                    }
                    return true // Continue
                } else {
                    return false // End of file
                }
            }) {}

            return String(format: "%08X", checksum).lowercased()
        } catch {
            print("\(self.TAG) Cannot get checksum: \(filePath.path)", error)
            return ""
        }
    }

    private func decryptFile(filePath: URL, sessionKey: String, version: String) throws {
        if self.privateKey.isEmpty || sessionKey.isEmpty  || sessionKey.components(separatedBy: ":").count != 2 {
            print("\(self.TAG) Cannot found privateKey or sessionKey")
            return
        }
        do {
            guard let rsaPrivateKey: RSAPrivateKey = .load(rsaPrivateKey: self.privateKey) else {
                print("cannot decode privateKey", self.privateKey)
                throw CustomError.cannotDecode
            }

            let sessionKeyArray: [String] = sessionKey.components(separatedBy: ":")
            guard let ivData: Data = Data(base64Encoded: sessionKeyArray[0]) else {
                print("cannot decode sessionKey", sessionKey)
                throw CustomError.cannotDecode
            }

            guard let sessionKeyDataEncrypted = Data(base64Encoded: sessionKeyArray[1]) else {
                throw NSError(domain: "Invalid session key data", code: 1, userInfo: nil)
            }

            guard let sessionKeyDataDecrypted = try? rsaPrivateKey.decrypt(data: sessionKeyDataEncrypted) else {
                throw NSError(domain: "Failed to decrypt session key data", code: 2, userInfo: nil)
            }

            let aesPrivateKey = AES128Key(iv: ivData, aes128Key: sessionKeyDataDecrypted)

            guard let encryptedData = try? Data(contentsOf: filePath) else {
                throw NSError(domain: "Failed to read encrypted data", code: 3, userInfo: nil)
            }

            guard let decryptedData = try? aesPrivateKey.decrypt(data: encryptedData) else {
                throw NSError(domain: "Failed to decrypt data", code: 4, userInfo: nil)
            }

            try decryptedData.write(to: filePath)
        } catch {
            print("\(self.TAG) Cannot decode: \(filePath.path)", error)
            self.sendStats(action: "decrypt_fail", versionName: version)
            throw CustomError.cannotDecode
        }
    }

    private func saveDownloaded(sourceZip: URL, id: String, base: URL) throws {
        try CapacitorUpdater.prepareFolder(source: base)
        let destHot: URL = base.appendingPathComponent(id)
        let destUnZip: URL = documentsDir.appendingPathComponent(randomString(length: 10))
        if !SSZipArchive.unzipFile(atPath: sourceZip.path, toDestination: destUnZip.path) {
            throw CustomError.cannotUnzip
        }
        if try unflatFolder(source: destUnZip, dest: destHot) {
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

    public func getLatest(url: URL) -> AppVersion {
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        let latest: AppVersion = AppVersion()
        let parameters: InfoObject = self.createInfoObject()
        print("\(self.TAG) Auto-update parameters: \(parameters)")
        let request = AF.request(url, method: .post, parameters: parameters, encoder: JSONParameterEncoder.default, requestModifier: { $0.timeoutInterval = self.timeout })

        request.validate().responseDecodable(of: AppVersionDec.self) { response in
            switch response.result {
            case .success:
                if let _ = response.value?.url {
                    // If we use partial and we get a response with url when manifest is expected we error.
                    // The backend should never allow this branch to be reached ;-)
                    print("\(self.TAG) Error getting latest (url != nil when partial)", response.value ?? "" )
                    latest.message = "Error getting latest (url != nil when partial) \(String(describing: response.value))"
                    latest.error = "response_error"
                }
                
                if let _ = response.value?.checksum {
                    print("\(self.TAG) Error getting latest (checksum != nil when partial)", response.value ?? "" )
                    latest.message = "Error getting latest (checksum != nil when partial) \(String(describing: response.value))"
                    latest.error = "response_error"
                }
                
                if let version = response.value?.version {
                    latest.version = version
                }
                if let manifest = response.value?.manifest {
                    latest.manifest = manifest
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
            case let .failure(error):
                print("\(self.TAG) Error getting Latest", response.value ?? "", error )
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
        print("\(self.TAG) Current bundle set to: \((bundle ).isEmpty ? BundleInfo.ID_BUILTIN : bundle)")
    }

    public func download(url: URL, version: String, sessionKey: String) throws -> BundleInfo {
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        let id: String = self.randomString(length: 10)
        var checksum: String = ""

        var mainError: NSError?
        let destination: DownloadRequest.Destination = { _, _ in
            let documentsURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileURL: URL = documentsURL.appendingPathComponent(self.randomString(length: 10))

            return (fileURL, [.removePreviousFile, .createIntermediateDirectories])
        }
        let request = AF.download(url, to: destination)

        request.downloadProgress { progress in
            let percent = self.calcTotalPercent(percent: Int(progress.fractionCompleted * 100), min: 10, max: 70)
            self.notifyDownload(id, percent)
        }
        request.responseURL(queue: .global(qos: .background), completionHandler: { (response) in
            if let fileURL = response.fileURL {
                switch response.result {
                case .success:
                    self.notifyDownload(id, 71)
                    do {
                        try self.decryptFile(filePath: fileURL, sessionKey: sessionKey, version: version)
                        checksum = self.getChecksum(filePath: fileURL)
                        try self.saveDownloaded(sourceZip: fileURL, id: id, base: self.documentsDir.appendingPathComponent(self.bundleDirectoryHot))
                        self.notifyDownload(id, 85)
                        try self.saveDownloaded(sourceZip: fileURL, id: id, base: self.libraryDir.appendingPathComponent(self.bundleDirectory))
                        self.notifyDownload(id, 100)
                        try self.deleteFolder(source: fileURL)
                    } catch {
                        print("\(self.TAG) download unzip error", error)
                        mainError = error as NSError
                    }
                case let .failure(error):
                    print("\(self.TAG) download error", response.value ?? "", error)
                    mainError = error as NSError
                }
            }
            semaphore.signal()
        })
        self.saveBundleInfo(id: id, bundle: BundleInfo(id: id, version: version, status: BundleStatus.DOWNLOADING, downloaded: Date(), checksum: checksum))
        self.notifyDownload(id, 0)
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
        if let error = mainError {
            throw error
        }
        let info: BundleInfo = BundleInfo(id: id, version: version, status: BundleStatus.PENDING, downloaded: Date(), checksum: checksum)
        self.saveBundleInfo(id: id, bundle: info)
        return info
    }
    
    public func downloadV2(manifestStorage: ManifestStorage, manifest: [DownloadManifestEntry], version: String, sessionKey: String) throws -> BundleInfo {
        
        var resultArr: Array<(any Error)?> = Array(repeating: nil, count: manifest.count)
        
        // First of all, we will copy the storage manifests entries
        let id: String = self.randomString(length: 10)
        
        // Now let's prepare the base folder for downloading
        let baseDir: URL = documentsDir.appendingPathComponent(bundleDirectoryHot).appendingPathComponent(id)
        try CapacitorUpdater.prepareFolder(source: baseDir)
        
        let group = DispatchGroup()
        for (i, downloadManifestEntry) in manifest.enumerated() {
            DispatchQueue.global(qos: .background).async(group: group) {
                let fileUrl = baseDir.appendingPathComponent(downloadManifestEntry.file_name)
                
                // Make sure we can copy/download
                do {
                    try CapacitorUpdater.prepareFolder(source: fileUrl.deletingLastPathComponent())
                } catch {
                    print("\(self.TAG) Could not prepare the parent download/copy folder (\(fileUrl.deletingLastPathComponent())). Error: \(error.localizedDescription)")
                    resultArr[i] = error
                }
                                
                if let manifestEntry = self.manifestStorage.cache[downloadManifestEntry.file_hash] {
                    print("\(self.TAG) Do not download, unzip \(downloadManifestEntry.file_name), \(Thread.current)")
                    
                    guard let toCopyFrom = manifestEntry.copyUrl() else {
                        print("\(self.TAG) No copy url, this is a very serious error")
                        return
                    }
                    
                    // Copy the file from the builtin bundle into the "documents" folder
                    do {
                        try FileManager.default.copyItem(at: toCopyFrom, to: fileUrl)
                    } catch {
                        print("\(self.TAG) Could not copy from the builtin bundle into the new url (\(fileUrl)) Error: \(error.localizedDescription)")
                        resultArr[i] = error
                    }
                    
                } else {
                    // Here we will download - this will not be easy
                    print("\(self.TAG) Not found, please download \(downloadManifestEntry.file_name), \(Thread.current)")
                    
                    // Verify the url
                    guard let _ = URL(string: downloadManifestEntry.download_url) else {
                        let error = "\(self.TAG) Cannot parse url (\(downloadManifestEntry.download_url)) Error: Please check the URL format"
                        print(error)
                        resultArr[i] = NSError(domain: error, code: 9, userInfo: nil)
                        return
                    }
                    
                    let downloadSemaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
                    var mainError: NSError?
                    
                    let destination: DownloadRequest.Destination = { _, _ in
                        // Please be aware - those 2 lines are duplicated
                        // I was unable to figure out how to escape the scope of a closure in swift
                        let baseDir: URL = self.documentsDir.appendingPathComponent(self.bundleDirectoryHot).appendingPathComponent(id)
                        let fileUrl = baseDir.appendingPathComponent(downloadManifestEntry.file_name)

                        return (fileUrl, [.removePreviousFile, .createIntermediateDirectories])
                    }
                    
                    let request = AF.download(downloadManifestEntry.download_url).validate(statusCode: 200..<300)
                    
                    request.responseData(queue: .global(qos: .background), completionHandler: { (response) in
                        defer {
                            downloadSemaphore.signal()
                        }
                        
                        switch response.result {
                        case .success:
                            if let responseData = response.value {
                                guard let unzipped = (responseData as NSData).gunzipped() as Data? else {
                                    let error = "Cannot unzip data"
                                    mainError = NSError(domain: error, code: 9)
                                    return
                                }
                                
                                do {
                                    try unzipped.write(to: fileUrl, options: [.atomic])
                                } catch {
                                    print("\(self.TAG) Cannot save file in the filesystem. Error: \(error.localizedDescription)")
                                    mainError = error as NSError
                                }
                                
                                let newEntry = ManifestEntry(filePath: fileUrl, hash: downloadManifestEntry.file_hash, type: .url)
                                manifestStorage.cache[newEntry.hash] = newEntry
                            }else {
                                let error = "Cannot find fileURL in the response"
                                mainError = NSError(domain: error, code: 9)
                            }
                        case let .failure(error):
                            print("\(self.TAG) download error: \(error) Detiald error: \(response.debugDescription)")
                            mainError = error as NSError
                        }
                    })
                    
                    downloadSemaphore.wait()
                    if let error = mainError {
                        // Loggin was done above, do not log twice
                        resultArr[i] = error
                        return
                    }
                }
            }
        }
        
        let waitResult = group.wait(timeout: DispatchTime.now() + DispatchTimeInterval.seconds(10))
        if (waitResult == DispatchTimeoutResult.timedOut) {
            print("\(self.TAG) Could not download, timed out")
            // TODO: comeback and figure out a better way. Also - timeout on android
            throw NSError(domain: "Download reached a timeout", code: 6, userInfo: nil)
        }
        
        // There is a chance that some files failed, let's check that
        let fails = resultArr.filter { $0 != nil }
        
        // 1 or more jobs failed. Inform the plugin
        if (!fails.isEmpty) {
            throw NSError(domain: "1 or more download job failed, please check logs", code: 7, userInfo: nil)
        }
        
        // Let's save the manifest
        manifestStorage.saveToDeviceStorage()
        
        // There is NO checksum with partial ;-)
        let info: BundleInfo = BundleInfo(id: id, version: version, status: BundleStatus.PENDING, downloaded: Date(), checksum: "")
        self.saveBundleInfo(id: id, bundle: info)
        return info
    }

    public func list() -> [BundleInfo] {
        let dest: URL = documentsDir.appendingPathComponent(bundleDirectoryHot)
        do {
            let files: [String] = try FileManager.default.contentsOfDirectory(atPath: dest.path)
            var res: [BundleInfo] = []
            print("\(self.TAG) list File : \(dest.path)")
            if dest.exist {
                for id: String in files {
                    res.append(self.getBundleInfo(id: id))
                }
            }
            return res
        } catch {
            print("\(self.TAG) No version available \(dest.path)")
            return []
        }
    }

    public func delete(id: String, removeInfo: Bool) -> Bool {
        let deleted: BundleInfo = self.getBundleInfo(id: id)
        if deleted.isBuiltin() || self.getCurrentBundleId() == id {
            print("\(self.TAG) Cannot delete \(id)")
            return false
        }
        let destHot: URL = documentsDir.appendingPathComponent(bundleDirectoryHot).appendingPathComponent(id)
        let destPersist: URL = libraryDir.appendingPathComponent(bundleDirectory).appendingPathComponent(id)
        do {
            try FileManager.default.removeItem(atPath: destHot.path)
        } catch {
            print("\(self.TAG) Hot Folder \(destHot.path), not removed.")
        }
        do {
            try FileManager.default.removeItem(atPath: destPersist.path)
        } catch {
            print("\(self.TAG) Folder \(destPersist.path), not removed.")
            return false
        }
        if removeInfo {
            self.removeBundleInfo(id: id)
        } else {
            self.saveBundleInfo(id: id, bundle: deleted.setStatus(status: BundleStatus.DELETED.localizedString))
        }
        print("\(self.TAG) bundle delete \(deleted.getVersionName())")
        self.sendStats(action: "delete", versionName: deleted.getVersionName())
        return true
    }

    public func delete(id: String) -> Bool {
        return self.delete(id: id, removeInfo: true)
    }

    public func getPathHot(id: String) -> URL {
        return documentsDir.appendingPathComponent(self.bundleDirectoryHot).appendingPathComponent(id)
    }

    public func getBundleDirectory(id: String) -> URL {
        return documentsDir.appendingPathComponent(bundleDirectoryHot).appendingPathComponent(id)
    }

    public func set(bundle: BundleInfo) -> Bool {
        return self.set(id: bundle.getId())
    }

    private func bundleExists(id: String) -> Bool {
        let destHot: URL = self.getPathHot(id: id)
        let destHotPersist: URL = self.getBundleDirectory(id: id)
        let indexHot: URL = destHot.appendingPathComponent("index.html")
        let indexPersist: URL = destHotPersist.appendingPathComponent("index.html")
        let bundleIndo: BundleInfo = self.getBundleInfo(id: id)
        if
            destHot.exist &&
                destHot.isDirectory &&
                destHotPersist.exist &&
                destHotPersist.isDirectory &&
                indexHot.exist &&
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
            self.setCurrentBundle(bundle: self.getBundleDirectory(id: id).path)
            self.setBundleStatus(id: id, status: BundleStatus.PENDING)
            self.sendStats(action: "set", versionName: newBundle.getVersionName())
            return true
        }
        self.setBundleStatus(id: id, status: BundleStatus.ERROR)
        self.sendStats(action: "set_fail", versionName: newBundle.getVersionName())
        return false
    }

    public func reset() {
        self.reset(isInternal: false)
    }

    public func reset(isInternal: Bool) {
        print("\(self.TAG) reset: \(isInternal)")
        self.setCurrentBundle(bundle: "")
        self.setFallbackBundle(fallback: Optional<BundleInfo>.none)
        _ = self.setNextBundle(next: Optional<String>.none)
        if !isInternal {
            self.sendStats(action: "reset", versionName: self.getCurrentBundle().getVersionName())
        }
    }

    public func setSuccess(bundle: BundleInfo, autoDeletePrevious: Bool) {
        self.setBundleStatus(id: bundle.getId(), status: BundleStatus.SUCCESS)
        let fallback: BundleInfo = self.getFallbackBundle()
        print("\(self.TAG) Fallback bundle is: \(fallback.toString())")
        print("\(self.TAG) Version successfully loaded: \(bundle.toString())")
        if autoDeletePrevious && !fallback.isBuiltin() {
            let res = self.delete(id: fallback.getId())
            if res {
                print("\(self.TAG) Deleted previous bundle: \(fallback.toString())")
            } else {
                print("\(self.TAG) Failed to delete previous bundle: \(fallback.toString())")
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
            print("\(self.TAG) Channel URL is not set")
            setChannel.message = "Channel URL is not set"
            setChannel.error = "missing_config"
            return setChannel
        }
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        var parameters: InfoObject = self.createInfoObject()

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
                print("\(self.TAG) Error unset Channel", response.value ?? "", error)
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
            print("\(self.TAG) Channel URL is not set")
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
                print("\(self.TAG) Error set Channel", response.value ?? "", error)
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
            print("\(self.TAG) Channel URL is not set")
            getChannel.message = "Channel URL is not set"
            getChannel.error = "missing_config"
            return getChannel
        }
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        let parameters: InfoObject = self.createInfoObject()
        let request = AF.request(self.channelUrl, method: .put, parameters: parameters, encoder: JSONParameterEncoder.default, requestModifier: { $0.timeoutInterval = self.timeout })

        request.validate().responseDecodable(of: GetChannelDec.self) { response in
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
                print("\(self.TAG) Error get Channel", response.value ?? "", error)
                getChannel.message = "Error get Channel \(String(describing: response.value)))"
                getChannel.error = "response_error"
            }
            semaphore.signal()
        }
        semaphore.wait()
        return getChannel
    }

    func sendStats(action: String, versionName: String) {
        if (self.statsUrl ).isEmpty {
            return
        }
        var parameters: InfoObject = self.createInfoObject()
        parameters.action = action
        DispatchQueue.global(qos: .background).async {
            let request = AF.request(self.statsUrl, method: .post, parameters: parameters, encoder: JSONParameterEncoder.default, requestModifier: { $0.timeoutInterval = self.timeout })
            request.responseData { response in
                switch response.result {
                case .success:
                    print("\(self.TAG) Stats send for \(action), version \(versionName)")
                case let .failure(error):
                    print("\(self.TAG) Error sending stats: ", response.value ?? "", error)
                }
            }
        }
    }

    public func getBundleInfo(id: String?) -> BundleInfo {
        var trueId = BundleInfo.VERSION_UNKNOWN
        if id != nil {
            trueId = id!
        }
        // print("\(self.TAG) Getting info for bundle [\(trueId)]")
        let result: BundleInfo
        if BundleInfo.ID_BUILTIN == trueId {
            result = BundleInfo(id: trueId, version: "", status: BundleStatus.SUCCESS, checksum: "")
        } else if BundleInfo.VERSION_UNKNOWN == trueId {
            result = BundleInfo(id: trueId, version: "", status: BundleStatus.ERROR, checksum: "")
        } else {
            do {
                result = try UserDefaults.standard.getObj(forKey: "\(trueId)\(self.INFO_SUFFIX)", castTo: BundleInfo.self)
            } catch {
                print("\(self.TAG) Failed to parse info for bundle [\(trueId)]", error.localizedDescription)
                result = BundleInfo(id: trueId, version: "", status: BundleStatus.PENDING, checksum: "")
            }
        }
        // print("\(self.TAG) Returning info bundle [\(result.toString())]")
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
            print("\(self.TAG) Not saving info for bundle [\(id)]", bundle?.toString() ?? "")
            return
        }
        if bundle == nil {
            print("\(self.TAG) Removing info for bundle [\(id)]")
            UserDefaults.standard.removeObject(forKey: "\(id)\(self.INFO_SUFFIX)")
        } else {
            let update = bundle!.setId(id: id)
            print("\(self.TAG) Storing info for bundle [\(id)]", update.toString())
            do {
                try UserDefaults.standard.setObj(update, forKey: "\(id)\(self.INFO_SUFFIX)")
            } catch {
                print("\(self.TAG) Failed to save info for bundle [\(id)]", error.localizedDescription)
            }
        }
        UserDefaults.standard.synchronize()
    }

    public func setVersionName(id: String, version: String) {
        print("\(self.TAG) Setting version for folder [\(id)] to \(version)")
        let info = self.getBundleInfo(id: id)
        self.saveBundleInfo(id: id, bundle: info.setVersionName(version: version))
    }

    private func setBundleStatus(id: String, status: BundleStatus) {
        print("\(self.TAG) Setting status for bundle [\(id)] to \(status)")
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
        if (bundlePath ).isEmpty {
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
        let bundle: URL = self.getBundleDirectory(id: nextId)
        if !newBundle.isBuiltin() && !bundle.exist {
            return false
        }
        UserDefaults.standard.set(nextId, forKey: self.NEXT_VERSION)
        UserDefaults.standard.synchronize()
        self.setBundleStatus(id: nextId, status: BundleStatus.PENDING)
        return true
    }
}
