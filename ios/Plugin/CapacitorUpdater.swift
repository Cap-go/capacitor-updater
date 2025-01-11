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
import zlib
import CryptoKit
import Compression

#if canImport(ZipArchive)
typealias ZipArchiveHelper = ZipArchive
#else
typealias ZipArchiveHelper = SSZipArchive
#endif

extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
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

public struct ManifestEntry: Codable {
    let file_name: String?
    let file_hash: String?
    let download_url: String?
}

extension ManifestEntry {
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [String: Any]()
        let mirror = Mirror(reflecting: self)
        for child in mirror.children {
            if let key = child.label {
                dict[key] = child.value
            }
        }
        return dict
    }
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
    let manifest: [ManifestEntry]?
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
    var manifest: [ManifestEntry]?
}

extension AppVersion {
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [String: Any]()
        let otherSelf: Mirror = Mirror(reflecting: self)
        for child: Mirror.Child in otherSelf.children {
            if let key: String = child.label {
                if key == "manifest", let manifestEntries = child.value as? [ManifestEntry] {
                    dict[key] = manifestEntries.map { $0.toDict() }
                } else {
                    dict[key] = child.value
                }
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
    case cannotDecryptSessionKey
    case invalidBase64

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
                comment: "Invalid public key"
            )
        case .cannotWrite:
            return NSLocalizedString(
                "Cannot write to the destination",
                comment: "Invalid destination"
            )
        case .cannotDecryptSessionKey:
            return NSLocalizedString(
                "Decrypting the session key failed",
                comment: "Invalid session key"
            )
        case .invalidBase64:
            return NSLocalizedString(
                "Decrypting the base64 failed",
                comment: "Invalid checksum key"
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

    // Add this line to declare cacheFolder
    private let cacheFolder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("capgo_downloads")

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
    public var deviceID = ""
    public var privateKey: String = ""
    public var publicKey: String = ""
    public var hasOldPrivateKeyPropertyInConfig: Bool = false

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

    private func decryptFileV2(filePath: URL, sessionKey: String, version: String) throws {
        if self.publicKey.isEmpty || sessionKey.isEmpty  || sessionKey.components(separatedBy: ":").count != 2 {
            print("\(self.TAG) Cannot find public key or sessionKey")
            return
        }
        do {
            guard let rsaPublicKey: RSAPublicKey = .load(rsaPublicKey: self.publicKey) else {
                print("cannot decode publicKey", self.publicKey)
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

            guard let sessionKeyDataDecrypted = rsaPublicKey.decrypt(data: sessionKeyDataEncrypted) else {
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

    private func decryptFile(filePath: URL, sessionKey: String, version: String) throws {
        if self.privateKey.isEmpty {
            print("\(self.TAG) Cannot found privateKey")
            return
        } else if sessionKey.isEmpty  || sessionKey.components(separatedBy: ":").count != 2 {
            print("\(self.TAG) Cannot found sessionKey")
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

        let success = ZipArchiveHelper.unzipFile(atPath: sourceZip.path,
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
                if let manifest = response.value?.manifest {
                    latest.manifest = manifest
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
            print("\(self.TAG) Cannot get checksum: \(filePath.path)", error)
            return ""
        }
    }

    private func calcChecksumV2(filePath: URL) -> String {
        let bufferSize = 1024 * 1024 * 5 // 5 MB
        var sha256 = SHA256()

        do {
            let fileHandle = try FileHandle(forReadingFrom: filePath)
            defer {
                fileHandle.closeFile()
            }

            while autoreleasepool(invoking: {
                let fileData = fileHandle.readData(ofLength: bufferSize)
                if fileData.count > 0 {
                    sha256.update(data: fileData)
                    return true // Continue
                } else {
                    return false // End of file
                }
            }) {}

            let digest = sha256.finalize()
            return digest.compactMap { String(format: "%02x", $0) }.joined()
        } catch {
            print("\(self.TAG) Cannot get checksum: \(filePath.path)", error)
            return ""
        }
    }

    private var tempDataPath: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("package.tmp")
    }

    private var updateInfo: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("update.dat")
    }
    private var tempData = Data()

    public func decryptChecksum(checksum: String, version: String) throws -> String {
        if self.publicKey.isEmpty {
            return checksum
        }
        do {
            let checksumBytes: Data = Data(base64Encoded: checksum)!
            guard let rsaPublicKey: RSAPublicKey = .load(rsaPublicKey: self.publicKey) else {
                print("cannot decode publicKey", self.publicKey)
                throw CustomError.cannotDecode
            }
            guard let decryptedChecksum = try? rsaPublicKey.decrypt(data: checksumBytes) else {
                throw NSError(domain: "Failed to decrypt session key data", code: 2, userInfo: nil)
            }
            return decryptedChecksum.base64EncodedString()
        } catch {
            print("\(self.TAG) Cannot decrypt checksum: \(checksum)", error)
            self.sendStats(action: "decrypt_fail", versionName: version)
            throw CustomError.cannotDecode
        }
    }

    private func verifyChecksum(file: URL, expectedHash: String) -> Bool {
        let actualHash = calcChecksumV2(filePath: file)
        return actualHash == expectedHash
    }

    public func downloadManifest(manifest: [ManifestEntry], version: String, sessionKey: String) throws -> BundleInfo {
        let id = self.randomString(length: 10)
        print("\(self.TAG) downloadManifest start \(id)")
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
                  let fileHash = entry.file_hash,
                  let downloadUrl = entry.download_url else {
                continue
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
                print("\(self.TAG) downloadManifest \(fileName) using builtin file \(id)")
                completedFiles += 1
                self.notifyDownload(id: id, percent: self.calcTotalPercent(percent: Int((Double(completedFiles) / Double(totalFiles)) * 100), min: 10, max: 70))
                dispatchGroup.leave()
            } else if FileManager.default.fileExists(atPath: cacheFilePath.path) && verifyChecksum(file: cacheFilePath, expectedHash: fileHash) {
                try FileManager.default.copyItem(at: cacheFilePath, to: destFilePath)
                print("\(self.TAG) downloadManifest \(fileName) copy from cache \(id)")
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

                            // Decompress the Brotli data
                            guard let decompressedData = self.decompressBrotli(data: data) else {
                                throw NSError(domain: "BrotliDecompressionError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decompress Brotli data"])
                            }
                            // Save decompressed data to cache
                            try decompressedData.write(to: cacheFilePath)
                            // Save decompressed data to destination
                            try decompressedData.write(to: destFilePath)

                            completedFiles += 1
                            self.notifyDownload(id: id, percent: self.calcTotalPercent(percent: Int((Double(completedFiles) / Double(totalFiles)) * 100), min: 10, max: 70))
                            print("\(self.TAG) downloadManifest \(id) \(fileName) downloaded, decompressed, and cached")
                        } catch {
                            downloadError = error
                            print("\(self.TAG) downloadManifest \(id) \(fileName) error: \(error)")
                        }
                    case .failure(let error):
                        print("\(self.TAG) downloadManifest \(id) \(fileName) download error: \(error). Debug response: \(response.debugDescription).")
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

        print("\(self.TAG) downloadManifest done \(id)")
        return updatedBundle
    }

    private func decompressBrotli(data: Data) -> Data? {
        let outputBufferSize = 65536
        var outputBuffer = [UInt8](repeating: 0, count: outputBufferSize)
        var decompressedData = Data()

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        var status = compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI)
        guard status != COMPRESSION_STATUS_ERROR else {
            print("\(self.TAG) Unable to initialize the decompression stream.")
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
                        print("\(self.TAG) Error: Unable to get base address of input data")
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
                print("\(self.TAG) Error during Brotli decompression")
                // Try to decode as text if mostly ASCII
                if let text = String(data: data, encoding: .utf8) {
                    let asciiCount = text.unicodeScalars.filter { $0.isASCII }.count
                    let totalCount = text.unicodeScalars.count
                    if totalCount > 0 && Double(asciiCount) / Double(totalCount) >= 0.8 {
                        print("\(self.TAG) Compressed data as text: \(text)")
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
                print("\(self.TAG) Downloading failed - ClosureEventMonitor activated")
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
                    print("\(self.TAG) Download failed")
                }

            case .complete:
                print("\(self.TAG) Download complete, total received bytes: \(totalReceivedBytes)")
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
            print("\(self.TAG) Failed to download: \(String(describing: mainError))")
            self.saveBundleInfo(id: id, bundle: BundleInfo(id: id, version: version, status: BundleStatus.ERROR, downloaded: Date(), checksum: checksum))
            throw mainError!
        }

        let finalPath = tempDataPath.deletingLastPathComponent().appendingPathComponent("\(id)")
        do {
            var checksumDecrypted = checksum
            if !self.hasOldPrivateKeyPropertyInConfig {
                try self.decryptFileV2(filePath: tempDataPath, sessionKey: sessionKey, version: version)
            } else {
                try self.decryptFile(filePath: tempDataPath, sessionKey: sessionKey, version: version)
            }
            try FileManager.default.moveItem(at: tempDataPath, to: finalPath)
        } catch {
            print("\(self.TAG) Failed decrypt file : \(error)")
            self.saveBundleInfo(id: id, bundle: BundleInfo(id: id, version: version, status: BundleStatus.ERROR, downloaded: Date(), checksum: checksum))
            cleanDownloadData()
            throw error
        }

        do {
            if !self.hasOldPrivateKeyPropertyInConfig && !sessionKey.isEmpty {
                checksum = self.calcChecksumV2(filePath: finalPath)
            } else {
                checksum = self.calcChecksum(filePath: finalPath)
            }
            print("\(self.TAG) Downloading: 80% (unzipping)")
            try self.saveDownloaded(sourceZip: finalPath, id: id, base: self.libraryDir.appendingPathComponent(self.bundleDirectory), notify: true)

        } catch {
            print("\(self.TAG) Failed to unzip file: \(error)")
            self.saveBundleInfo(id: id, bundle: BundleInfo(id: id, version: version, status: BundleStatus.ERROR, downloaded: Date(), checksum: checksum))
            cleanDownloadData()
            // todo: cleanup zip attempts
            throw error
        }

        self.notifyDownload(id: id, percent: 90)
        print("\(self.TAG) Downloading: 90% (wrapping up)")
        let info = BundleInfo(id: id, version: version, status: BundleStatus.PENDING, downloaded: Date(), checksum: checksum)
        self.saveBundleInfo(id: id, bundle: info)
        self.cleanDownloadData()
        self.notifyDownload(id: id, percent: 100)
        print("\(self.TAG) Downloading: 100% (complete)")
        return info
    }
    private func ensureResumableFilesExist() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: tempDataPath.path) {
            if !fileManager.createFile(atPath: tempDataPath.path, contents: Data()) {
                print("\(self.TAG) Cannot ensure that a file at \(tempDataPath.path) exists")
            }
        }

        if !fileManager.fileExists(atPath: updateInfo.path) {
            if !fileManager.createFile(atPath: updateInfo.path, contents: Data()) {
                print("\(self.TAG) Cannot ensure that a file at \(updateInfo.path) exists")
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
                print("\(self.TAG) Could not delete file at \(tempDataPath): \(error)")
            }
        }
        // Deleting update.dat
        if fileManager.fileExists(atPath: updateInfo.path) {
            do {
                try fileManager.removeItem(at: updateInfo)
            } catch {
                print("\(self.TAG) Could not delete file at \(updateInfo): \(error)")
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
            print("\(self.TAG) Failed to save progress: \(error)")
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
            print("\(self.TAG) Could not retrieve already downloaded data size : \(error)")
        }
        return 0
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

        // Check if this is the next bundle and prevent deletion if it is
        if let next = self.getNextBundle(),
           !next.isDeleted() &&
           !next.isErrorStatus() &&
           next.getId() == id {
            print("\(self.TAG) Cannot delete the next bundle \(id)")
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

                print("\(self.TAG) Error get Channel", response.value ?? "", error)
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
                    print("\(self.TAG) Stats sent for \(action), version \(versionName)")
                case let .failure(error):
                    print("\(self.TAG) Error sending stats: ", response.value ?? "", error.localizedDescription)
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
