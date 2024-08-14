/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import SSZipArchive
import Alamofire
import zlib

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
    var version_name: String?
    var old_version_name: String?
    let plugin_version: String?
    let is_emulator: Bool?
    let is_prod: Bool?
    var action: String?
    var channel: String?
    var defaultChannel: String?
}
struct AppVersionDec: Decodable {
    let version: String?
    let checksum: String?
    let url: String?
    let message: String?
    let error: String?
    let session_key: String?
    let major: Bool?
    let data: [String: String]?
}
public class AppVersion: NSObject {
    var version: String = ""
    var checksum: String = ""
    var url: String = ""
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
    private let libraryDir: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
    private let DEFAULT_FOLDER: String = ""
    private let bundleDirectory: String = "NoCloud/ionic_built_snapshots"
    private let INFO_SUFFIX: String = "_info"
    private let FALLBACK_VERSION: String = "pastVersion"
    private let NEXT_VERSION: String = "nextVersion"
    private var unzipPercent = 0

    public let TAG: String = "✨  Capacitor-updater:"
    public let CAP_SERVER_PATH: String = "serverBasePath"
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
                print("\(self.TAG) Cannot createDirectory \(source.path)")
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

    private func calcChecksum(filePath: URL) -> String {
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
            print("\(self.TAG) Cannot calc checksum: \(filePath.path)", error)
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

            guard let sessionKeyDataDecrypted = rsaPrivateKey.decrypt(data: sessionKeyDataEncrypted) else {
                throw NSError(domain: "Failed to decrypt session key data", code: 2, userInfo: nil)
            }

            let aesPrivateKey = AES128Key(iv: ivData, aes128Key: sessionKeyDataDecrypted)

            guard let encryptedData = try? Data(contentsOf: filePath) else {
                throw NSError(domain: "Failed to read encrypted data", code: 3, userInfo: nil)
            }

            guard let decryptedData = aesPrivateKey.decrypt(data: encryptedData) else {
                throw NSError(domain: "Failed to decrypt data", code: 4, userInfo: nil)
            }

            try decryptedData.write(to: filePath)
           
        } catch {
            print("\(self.TAG) Cannot decode: \(filePath.path)", error)
            self.sendStats(action: "decrypt_fail", versionName: version)
            throw CustomError.cannotDecode
        }
    }

    private func unzipProgressHandler(entry: String, zipInfo: unz_file_info, entryNumber: Int, total: Int, destUnZip: URL, id: String, unzipError: inout NSError?) {
        if entry.contains("\\") {
            print("\(self.TAG) unzip: Windows path is not supported, please use unix path as required by zip RFC: \(entry)")
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
            self.notifyDownload(id, newPercent)
        }
    }

    private func saveDownloaded(sourceZip: URL, id: String, base: URL, notify: Bool) throws {
        try prepareFolder(source: base)
        let destPersist: URL = base.appendingPathComponent(id)
        let destUnZip: URL = libraryDir.appendingPathComponent(randomString(length: 10))

        self.unzipPercent = 0
        self.notifyDownload(id, 75)

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

    public func getLatest(url: URL) -> AppVersion {
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        let latest: AppVersion = AppVersion()
        let parameters: InfoObject = self.createInfoObject()
        print("\(self.TAG) Auto-update parameters: \(parameters)")
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
    //Do a GET request on the url in order to extract the Content-Length header, ask only for the 10 first bytes in order to not download the full content.
    func fetchFileSize(url: URL) -> Int? {
        let semaphore = DispatchSemaphore(value: 0)
        var fileSize: Int?
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range") //Asking for 0 byte in the response body, in order to not download the file

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                print("Error while requesting file size : \(error)")
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                print("Could not perform the request because of a client or server error.")
                return

            }

            if let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range") { //Extracting the Content-Range header from the partial response
                let parts = contentRange.split(separator: "/").map(String.init)
                if parts.count > 1, let totalSize = Int(parts[1]) {
                    fileSize = totalSize
                }
            }
        }

        task.resume()
        semaphore.wait()

        return fileSize
    }


    
    private var tempDataPath: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("package.tmp")
    }

    private var progressPath: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("progress.dat")
    }
    private var tempData = Data()
    public func download(url: URL, version: String, sessionKey: String) throws -> BundleInfo {
        let id: String = self.randomString(length: 10)
        let semaphore = DispatchSemaphore(value: 0)
        var checksum = ""
        let targetSize = fetchFileSize(url: url) //Fetching the total size of the file
        var totalReceivedBytes: Int64 = loadDownloadProgress() //Retrieving the amount of already downloaded data if exist, defined at 0 otherwise
         let requestHeaders: HTTPHeaders = ["Range": "bytes=\(totalReceivedBytes)-"]
        //Opening connection for streaming the bytes
         AF.streamRequest(url, headers: requestHeaders).validate().responseStream { [weak self] streamResponse in
             guard let self = self else { return }

             switch streamResponse.event {
                 
             case .stream(let result):
                 switch result {
                 case .success(let data):

                     self.tempData.append(data)
                     
                     self.savePartialData(startingAt: UInt64(totalReceivedBytes)) //Saving the received data in the package.tmp file
                     totalReceivedBytes += Int64(data.count)
                     
                     self.saveDownloadProgress(totalReceivedBytes)
                     let percent = Int((Double(totalReceivedBytes) / Double(targetSize ?? 1)) * 100.0)
                     print("Downloading : \(percent)%")
                 default:
                     print("Download failed")
                 }

             case .complete(_):
                print("Download complete, total received bytes: \(totalReceivedBytes)")
                semaphore.signal()
             }
         }

        semaphore.wait()

        try self.decryptFile(filePath: tempDataPath, sessionKey: sessionKey, version: version)
        let finalPath = tempDataPath.deletingLastPathComponent().appendingPathComponent("\(id)")
        do {
            try FileManager.default.moveItem(at: tempDataPath, to: finalPath)
            
            checksum = self.getChecksum(filePath: finalPath)
            try self.saveDownloaded(sourceZip: finalPath, id: id, base: self.libraryDir.appendingPathComponent(self.bundleDirectory), notify: true)
            print(self.libraryDir.appendingPathComponent(self.bundleDirectory))
        } catch {
            print("Failed to unzip file: \(error)")
            cleanDlData()
        }
        
        
        
        let info = BundleInfo(id: id, version: version, status: BundleStatus.SUCCESS, downloaded: Date(), checksum: checksum)
        self.saveBundleInfo(id: id, bundle: info)
        self.notifyDownload(id, 100)
        self.cleanDlData()
        return info
    }
    private func cleanDlData(){
        // Deleting package.tmp
        let fileManager = FileManager.default
         if fileManager.fileExists(atPath: tempDataPath.path) {
             do {
                 try fileManager.removeItem(at: tempDataPath)
             } catch {
                 print("Could not delete file at \(tempDataPath): \(error)")
             }
         } else {
             print("\(tempDataPath.lastPathComponent) does not exist")
         }
         
         // Deleting progress.dat
         if fileManager.fileExists(atPath: progressPath.path) {
             do {
                 try fileManager.removeItem(at: progressPath)
             } catch {
                 print("Could not delete file at \(progressPath): \(error)")
             }
         } else {
             print("\(progressPath.lastPathComponent) does not exist")
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


    private func saveDownloadProgress(_ bytes: Int64) {
        do {
            try "\(bytes)".write(to: progressPath, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to save progress: \(error)")
        }
    }

    private func loadDownloadProgress() -> Int64 {
        guard let progressString = try? String(contentsOf: progressPath),
              let progress = Int64(progressString) else {
            return 0
        }
        return progress
    }





    public func list() -> [BundleInfo] {
        let dest: URL = libraryDir.appendingPathComponent(bundleDirectory)
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
        let destPersist: URL = libraryDir.appendingPathComponent(bundleDirectory).appendingPathComponent(id)
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
            print("\(self.TAG) Folder at bundle path does not exist. Triggering reset.")
            self.reset()
        }
    }

    public func reset() {
        self.reset(isInternal: false)
    }

    public func reset(isInternal: Bool) {
        print("\(self.TAG) reset: \(isInternal)")
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
        print("\(self.TAG) Fallback bundle is: \(fallback.toString())")
        print("\(self.TAG) Version successfully loaded: \(bundle.toString())")
        if autoDeletePrevious && !fallback.isBuiltin() && fallback.getId() != bundle.getId() {
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

    func sendStats(action: String, versionName: String? = nil, oldVersionName: String? = "") {
        guard !statsUrl.isEmpty else {
            return
        }

        let versionName = versionName ?? getCurrentBundle().getVersionName()

        var parameters = createInfoObject()
        parameters.action = action
        parameters.version_name = versionName
        parameters.old_version_name = oldVersionName

        DispatchQueue.global(qos: .background).async {
            let request = AF.request(
                self.statsUrl,
                method: .post,
                parameters: parameters,
                encoder: JSONParameterEncoder.default,
                requestModifier: { $0.timeoutInterval = self.timeout }
            )

            request.responseData { response in
                switch response.result {
                case .success:
                    print("\(self.TAG) Stats sent for \(action), version \(versionName)")
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
