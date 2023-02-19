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
extension Date {
    func adding(minutes: Int) -> Date {
        return Calendar.current.date(byAdding: .minute, value: minutes, to: self)!
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
    let deviceId: String?
    let appId: String?
    let customId: String?
    let versionBuild: String?
    let versionCode: String?
    let versionOS: String?
    let versionName: String?
    let pluginVersion: String?
    let isEmulator: Bool?
    let isProd: Bool?
    var action: String?
    var channel: String?
}
struct AppVersionDec: Decodable {
    let version: String?
    let checksum: String?
    let url: String?
    let message: String?
    let error: String?
    let session_key: String?
    let major: Bool?
}
public class AppVersion: NSObject {
    var version: String = ""
    var checksum: String = ""
    var url: String = ""
    var message: String?
    var error: String?
    var sessionKey: String?
    var major: Bool?
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

    private let versionName: String = Bundle.main.versionName ?? ""
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
    public let CAP_SERVER_PATH: String = "serverBasePath"
    public var customId: String = ""
    public var PLUGIN_VERSION: String = ""
    public let timeout: Double = 20
    public var statsUrl: String = ""
    public var channelUrl: String = ""
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

    private func isProd() -> Bool {
        return !self.isAppStoreReceiptSandbox() && !self.hasEmbeddedMobileProvision()
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

    private func getChecksum(filePath: URL) -> String {
        do {
            let fileData: Data = try Data.init(contentsOf: filePath)
            let checksum: uLong = fileData.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(fileData.count)) }
            return String(format: "%08X", checksum).lowercased()
        } catch {
            print("\(self.TAG) Cannot get checksum: \(filePath.path)", error)
            return ""
        }
    }

    private func decryptFile(filePath: URL, sessionKey: String) throws {
        if (self.privateKey ?? "").isEmpty || (sessionKey ?? "").isEmpty {
            print("\(self.TAG) Cannot found privateKey or sessionKey")
            return
        }
        do {
            guard let rsaPrivateKey: RSAPrivateKey = .load(rsaPrivateKey: self.privateKey) else {
                print("cannot decode privateKey", self.privateKey)
                return
            }

            let sessionKeyArray: [String] = sessionKey.components(separatedBy: ":")
            guard let ivData: Data = Data(base64Encoded: sessionKeyArray[0]) else {
                print("cannot decode sessionKey", sessionKey)
                return
            }
            let sessionKeyDataEncrypted: Data = Data(base64Encoded: sessionKeyArray[1])!
            let sessionKeyDataDecrypted: Data = rsaPrivateKey.decrypt(data: sessionKeyDataEncrypted)!
            let aesPrivateKey: AES128Key = AES128Key(iv: ivData, aes128Key: sessionKeyDataDecrypted)
            let encryptedData: Data = try Data(contentsOf: filePath)
            let decryptedData: Data = aesPrivateKey.decrypt(data: encryptedData)!

            try decryptedData.write(to: filePath)
        } catch {
            print("\(self.TAG) Cannot decode: \(filePath.path)", error)
            throw CustomError.cannotDecode
        }
    }

    private func saveDownloaded(sourceZip: URL, id: String, base: URL) throws {
        try prepareFolder(source: base)
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
            deviceId: self.deviceID,
            appId: self.appId,
            customId: self.customId,
            versionBuild: self.versionName,
            versionCode: self.versionCode,
            versionOS: self.versionOs,
            versionName: self.getCurrentBundle().getVersionName(),
            pluginVersion: self.PLUGIN_VERSION,
            isEmulator: self.isEmulator(),
            isProd: self.isProd(),
            action: nil,
            channel: nil
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
        print("\(self.TAG) Current bundle set to: \((bundle ?? "").isEmpty ? BundleInfo.idBuiltin : bundle)")
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
        request.responseURL { (response) in
            if let fileURL = response.fileURL {
                switch response.result {
                case .success:
                    self.notifyDownload(id, 71)
                    do {
                        try self.decryptFile(filePath: fileURL, sessionKey: sessionKey)
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
                    print("\(self.TAG) download error", response.value!, error)
                    mainError = error as NSError
                }
            }
            semaphore.signal()
        }
        self.saveBundleInfo(id: id, bundle: BundleInfo(id: id, version: version, status: BundleStatus.DOWNLOADING, downloaded: Date(), checksum: checksum))
        self.notifyDownload(id, 0)
        semaphore.wait()
        if mainError != nil {
            throw mainError!
        }
        let info: BundleInfo = BundleInfo(id: id, version: version, status: BundleStatus.PENDING, downloaded: Date(), checksum: checksum)
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

    public func getBundleDirectory(id: String) -> URL {
        return libraryDir.appendingPathComponent(self.bundleDirectory).appendingPathComponent(id)
    }

    public func set(bundle: BundleInfo) -> Bool {
        return self.set(id: bundle.getId())
    }

    private func bundleExists(id: String) -> Bool {
        let destHot: URL = self.getPathHot(id: id)
        let destHotPersist: URL = self.getPathPersist(id: id)
        let indexHot: URL = destHot.appendingPathComponent("index.html")
        let indexPersist: URL = destHotPersist.appendingPathComponent("index.html")
        let url: URL = self.getBundleDirectory(id: id)
        let bundleIndo: BundleInfo = self.getBundleInfo(id: id)
        if url.isDirectory && destHotPersist.isDirectory && indexHot.exist && indexPersist.exist && !bundleIndo.isDeleted() {
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
        self.sendStats(action: "set_fail", versionName: newBundle.getVersionName())
        return false
    }

    public func getPathHot(id: String) -> URL {
        return documentsDir.appendingPathComponent(self.bundleDirectoryHot).appendingPathComponent(id)
    }

    public func getPathPersist(id: String) -> URL {
        return libraryDir.appendingPathComponent(self.bundleDirectory).appendingPathComponent(id)
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

    func setChannel(channel: String) -> SetChannel {
        let setChannel: SetChannel = SetChannel()
        if (self.channelUrl ?? "").isEmpty {
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
                print("\(self.TAG) Error set Channel", response.value, error)
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
        if (self.channelUrl ?? "").isEmpty {
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
        if (self.statsUrl ?? "").isEmpty {
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
                    print("\(self.TAG) Error sending stats: ", response.value, error)
                }
            }
        }
    }

    public func getBundleInfo(id: String?) -> BundleInfo {
        var trueId = BundleInfo.versionUnknown
        if id != nil {
            trueId = id!
        }
        print("\(self.TAG) Getting info for bundle [\(trueId)]")
        let result: BundleInfo
        if BundleInfo.idBuiltin == trueId {
            result = BundleInfo(id: trueId, version: "", status: BundleStatus.SUCCESS, checksum: "")
        } else if BundleInfo.versionUnknown == trueId {
            result = BundleInfo(id: trueId, version: "", status: BundleStatus.ERROR, checksum: "")
        } else {
            do {
                result = try UserDefaults.standard.getObj(forKey: "\(trueId)\(self.INFO_SUFFIX)", castTo: BundleInfo.self)
            } catch {
                print("\(self.TAG) Failed to parse info for bundle [\(trueId)]", error.localizedDescription)
                result = BundleInfo(id: trueId, version: "", status: BundleStatus.PENDING, checksum: "")
            }
        }
        print("\(self.TAG) Returning info bundle [\(result.toString())]")
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

    private func saveBundleInfo(id: String, bundle: BundleInfo?) {
        if bundle != nil && (bundle!.isBuiltin() || bundle!.isUnknown()) {
            print("\(self.TAG) Not saving info for bundle [\(id)]", bundle!.toString())
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
            return BundleInfo.idBuiltin
        }
        if (bundlePath ?? "").isEmpty {
            return BundleInfo.idBuiltin
        }
        let bundleID: String = bundlePath.components(separatedBy: "/").last ?? bundlePath
        return bundleID
    }

    public func isUsingBuiltin() -> Bool {
        return (UserDefaults.standard.string(forKey: self.CAP_SERVER_PATH) ?? "") == self.DEFAULT_FOLDER
    }

    public func getFallbackBundle() -> BundleInfo {
        let id: String = UserDefaults.standard.string(forKey: self.FALLBACK_VERSION) ?? BundleInfo.idBuiltin
        return self.getBundleInfo(id: id)
    }

    private func setFallbackBundle(fallback: BundleInfo?) {
        UserDefaults.standard.set(fallback == nil ? BundleInfo.idBuiltin : fallback!.getId(), forKey: self.FALLBACK_VERSION)
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
