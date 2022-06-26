import Foundation
import SSZipArchive
import Alamofire

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
struct AppVersionDec: Decodable {
    let version: String?
    let url: String?
    let message: String?
    let major: Bool?
}
public class AppVersion: NSObject {
    var version: String = ""
    var url: String = ""
    var message: String?
    var major: Bool?
}
extension OperatingSystemVersion {
    func getFullVersion(separator: String = ".") -> String {
        return "\(majorVersion)\(separator)\(minorVersion)\(separator)\(patchVersion)"
    }
}
extension Bundle {
    var releaseVersionNumber: String? {
        return infoDictionary?["CFBundleShortVersionString"] as? String
    }
    var buildVersionNumber: String? {
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
    static let iso8601withFractionalSeconds = ISO8601DateFormatter([.withInternetDateTime, .withFractionalSeconds])
}
extension Date {
    var iso8601withFractionalSeconds: String { return Formatter.iso8601withFractionalSeconds.string(from: self) }
}
extension String {
    
    var fileURL: URL {
        return URL(fileURLWithPath: self)
    }
    
    var lastPathComponent:String {
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
        case .unexpected(_):
            return NSLocalizedString(
                "An unexpected error occurred.",
                comment: "Unexpected Error"
            )
        }
    }
}

@objc public class CapacitorUpdater: NSObject {
    
    private let versionBuild = Bundle.main.releaseVersionNumber ?? ""
    private let versionCode = Bundle.main.buildVersionNumber ?? ""
    private let versionOs = ProcessInfo().operatingSystemVersion.getFullVersion()
    private let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    private let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
    private let bundleDirectoryHot = "versions"
    private let DEFAULT_FOLDER = ""
    private let bundleDirectory = "NoCloud/ionic_built_snapshots"
    private let INFO_SUFFIX = "_info"
    private let FALLBACK_VERSION = "pastVersion"
    private let NEXT_VERSION = "nextVersion"

    private var lastPathHot = ""
    private var lastPathPersist = ""
    
    public let TAG = "✨  Capacitor-updater:";
    public let CAP_SERVER_PATH = "serverBasePath"
    public let pluginVersion = "3.2.0"
    public var statsUrl = ""
    public var appId = ""
    public var deviceID = UIDevice.current.identifierForVendor?.uuidString ?? ""
    
    public var notifyDownload: (String, Int) -> Void = { _,_  in }

    private func calcTotalPercent(percent: Int, min: Int, max: Int) -> Int {
        return (percent * (max - min)) / 100 + min;
    }
    
    private func randomString(length: Int) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map{ _ in letters.randomElement()! })
    }
    
    // Persistent path /var/mobile/Containers/Data/Application/8C0C07BE-0FD3-4FD4-B7DF-90A88E12B8C3/Library/NoCloud/ionic_built_snapshots/FOLDER
    // Hot Reload path /var/mobile/Containers/Data/Application/8C0C07BE-0FD3-4FD4-B7DF-90A88E12B8C3/Documents/FOLDER
    // Normal /private/var/containers/Bundle/Application/8C0C07BE-0FD3-4FD4-B7DF-90A88E12B8C3/App.app/public
    
    private func prepareFolder(source: URL) throws {
        if (!FileManager.default.fileExists(atPath: source.path)) {
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
        let index = source.appendingPathComponent("index.html")
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: source.path)
            if (files.count == 1 && source.appendingPathComponent(files[0]).isDirectory && !FileManager.default.fileExists(atPath: index.path)) {
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
    
    private func saveDownloaded(sourceZip: URL, folder: String, base: URL) throws {
        try prepareFolder(source: base)
        let destHot = base.appendingPathComponent(folder)
        let destUnZip = documentsDir.appendingPathComponent(randomString(length: 10))
        if (!SSZipArchive.unzipFile(atPath: sourceZip.path, toDestination: destUnZip.path)) {
            throw CustomError.cannotUnzip
        }
        if (try unflatFolder(source: destUnZip, dest: destHot)) {
            try deleteFolder(source: destUnZip)
        }
    }

    public func getLatest(url: URL) -> AppVersion? {
        let semaphore = DispatchSemaphore(value: 0)
        let latest = AppVersion()
        let headers: HTTPHeaders = [
            "cap_platform": "ios",
            "cap_device_id": self.deviceID,
            "cap_app_id": self.appId,
            "cap_version_build": self.versionBuild,
            "cap_version_code": self.versionCode,
            "cap_version_os": self.versionOs,
            "cap_plugin_version": self.pluginVersion,
            "cap_version_name": self.getCurrentBundle().getVersionName()
        ]
        let request = AF.request(url, headers: headers)

        request.validate().responseDecodable(of: AppVersionDec.self) { response in
            switch response.result {
                case .success:
                    if let url = response.value?.url {
                        latest.url = url
                    }
                    if let version = response.value?.version {
                        latest.version = version
                    }
                    if let major = response.value?.major {
                        latest.major = major
                    }
                    if let message = response.value?.message {
                        latest.message = message
                        print("\(self.TAG) Auto-update message: \(message)")
                    }
                case let .failure(error):
                    print("\(self.TAG) Error getting Latest", error )
            }
            semaphore.signal()
        }
        semaphore.wait()
        return latest.url != "" ? latest : nil
    }
    
    private func setCurrentBundle(bundle: String) {
        UserDefaults.standard.set(bundle, forKey: self.CAP_SERVER_PATH)
        print("\(self.TAG) Current bundle set to: \(bundle)")
        UserDefaults.standard.synchronize()
    }

    public func download(url: URL, versionName: String) throws -> VersionInfo {
        let semaphore = DispatchSemaphore(value: 0)
        let folder: String = self.randomString(length: 10)
        var mainError: NSError? = nil
        let destination: DownloadRequest.Destination = { _, _ in
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileURL = documentsURL.appendingPathComponent(self.randomString(length: 10))

            return (fileURL, [.removePreviousFile, .createIntermediateDirectories])
        }
        let request = AF.download(url, to: destination)
        
        request.downloadProgress { progress in
            let percent = self.calcTotalPercent(percent: Int(progress.fractionCompleted * 100), min: 10, max: 70)
            self.notifyDownload(folder, percent)
        }
        request.responseURL { (response) in
            if let fileURL = response.fileURL {
                switch response.result {
                case .success:
                    self.notifyDownload(folder, 71)
                    do {
                        try self.saveDownloaded(sourceZip: fileURL, folder: folder, base: self.documentsDir.appendingPathComponent(self.bundleDirectoryHot))
                        self.notifyDownload(folder, 85)
                        try self.saveDownloaded(sourceZip: fileURL, folder: folder, base: self.libraryDir.appendingPathComponent(self.bundleDirectory))
                        self.notifyDownload(folder, 100)
                        try self.deleteFolder(source: fileURL)
                    } catch {
                        print("\(self.TAG) download unzip error", error)
                        mainError = error as NSError
                    }
                case let .failure(error):
                    print("\(self.TAG) download error", error)
                    mainError = error as NSError
                }
            }
            semaphore.signal()
        }
        self.saveVersionInfo(folder: folder, info: VersionInfo(folder: folder, versionName: versionName, status: VersionStatus.DOWNLOADING, downloaded: Date()))
        self.notifyDownload(folder, 0)
        semaphore.wait()
        if (mainError != nil) {
            throw mainError!
        }
        let info: VersionInfo = VersionInfo(folder: folder, versionName: versionName, status: VersionStatus.PENDING, downloaded: Date())
        self.saveVersionInfo(folder: folder, info: info)
        return info
    }

    public func list() -> [VersionInfo] {
        let dest = documentsDir.appendingPathComponent(bundleDirectoryHot)
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: dest.path)
            var res: [VersionInfo] = []
            print("\(self.TAG) list File : \(dest.path)")
            if (dest.exist) {
                for folder in files {
                    res.append(self.getVersionInfo(folder: folder));
                }
            }
            return res
        } catch {
            print("\(self.TAG) No version available \(dest.path)")
            return []
        }
    }
    
    public func delete(folder: String) -> Bool {
        let deleted: VersionInfo = self.getVersionInfo(folder: folder)
        let destHot = documentsDir.appendingPathComponent(bundleDirectoryHot).appendingPathComponent(folder)
        let destPersist = libraryDir.appendingPathComponent(bundleDirectory).appendingPathComponent(folder)
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
        self.removeVersionInfo(folder: folder)
        self.sendStats(action: "delete", version: deleted)
        return true
    }

    public func getBundleDirectory(folder: String) -> URL {
        return libraryDir.appendingPathComponent(self.bundleDirectory).appendingPathComponent(folder)
    }

    public func set(version: VersionInfo) -> Bool {
        return self.set(folder: version.getFolder());
    }

    public func set(folder: String) -> Bool {
        let destHot = self.getPathHot(folderName: folder)
        let destHotPersist = self.getPathPersist(folderName: folder)
        let indexHot = destHot.appendingPathComponent("index.html")
        let indexPersist = destHotPersist.appendingPathComponent("index.html")
        let existing: VersionInfo = self.getVersionInfo(folder: folder)
        let bundle: URL = self.getBundleDirectory(folder: folder)
        print("bundle", bundle.path)
        if (bundle.isDirectory && destHotPersist.isDirectory && indexHot.exist && indexPersist.exist) {
            self.setCurrentBundle(bundle: String(bundle.path.suffix(10)))
            self.setVersionStatus(folder: folder, status: VersionStatus.PENDING)
            sendStats(action: "set", version: existing)
            return true
        }
        sendStats(action: "set_fail", version: existing)
        return false
    }
    
    public func getPathHot(folderName: String) -> URL {
        return documentsDir.appendingPathComponent(self.bundleDirectoryHot).appendingPathComponent(folderName)
    }
    
    public func getPathPersist(folderName: String) -> URL {
        return libraryDir.appendingPathComponent(self.bundleDirectory).appendingPathComponent(folderName)
    }
    
    public func reset() {
        self.reset(isInternal: false)
    }
    
    public func reset(isInternal: Bool) {
        self.setCurrentBundle(bundle: "")
        self.setFallbackVersion(fallback: Optional<VersionInfo>.none)
        let _ = self.setNextVersion(next: Optional<String>.none)
        UserDefaults.standard.synchronize()
        if(!isInternal) {
            sendStats(action: "reset", version: self.getCurrentBundle())
        }
    }
    
    public func commit(version: VersionInfo) {
        self.setVersionStatus(folder: version.getFolder(), status: VersionStatus.SUCCESS)
        self.setFallbackVersion(fallback: version)
    }
    
    public func rollback(version: VersionInfo) {
        self.setVersionStatus(folder: version.getFolder(), status: VersionStatus.ERROR);
    }

    func sendStats(action: String, version: VersionInfo) {
        if (statsUrl == "") { return }
        let parameters: [String: String] = [
            "platform": "ios",
            "action": action,
            "device_id": self.deviceID,
            "version_name": version.getVersionName(),
            "version_build": self.versionBuild,
            "version_code": self.versionCode,
            "version_os": self.versionOs,
            "plugin_version": self.pluginVersion,
            "app_id": self.appId
        ]

        DispatchQueue.global(qos: .background).async {
            let _ = AF.request(self.statsUrl, method: .post,parameters: parameters, encoder: JSONParameterEncoder.default)
            print("\(self.TAG) Stats send for \(action), version \(version.getVersionName())")
        }
    }

    public func getVersionInfo(folder: String = VersionInfo.VERSION_BUILTIN) -> VersionInfo {
        print("\(self.TAG) Getting info for [\(folder)]")
        if(VersionInfo.VERSION_BUILTIN == folder) {
            return VersionInfo(folder: folder, versionName: "", status: VersionStatus.SUCCESS)
        }
        do {
            let result: VersionInfo = try UserDefaults.standard.getObj(forKey: "\(folder)\(self.INFO_SUFFIX)", castTo: VersionInfo.self)
            print("\(self.TAG) Returning info [\(folder)]", result.toString())
            return result
        } catch {
            print("\(self.TAG) Failed to parse version info for [\(folder)]", error.localizedDescription)
            return VersionInfo(folder: folder, versionName: "", status: VersionStatus.PENDING)
        }
    }

    public func getVersionInfoByVersionName(versionName: String) -> VersionInfo? {
        let installed : Array<VersionInfo> = self.list()
        for i in installed {
            if(i.getVersionName() == versionName) {
                return i
            }
        }
        return nil
    }

    private func removeVersionInfo(folder: String) {
        self.saveVersionInfo(folder: folder, info: nil)
    }

    private func saveVersionInfo(folder: String, info: VersionInfo?) {
        if (info != nil && (info!.isBuiltin() || info!.isUnknown())) {
            print("\(self.TAG) Not saving info for folder [\(folder)]", info!.toString())
            return
        }
        if(info == nil) {
            print("\(self.TAG) Removing info for folder [\(folder)]")
            UserDefaults.standard.removeObject(forKey: "\(folder)\(self.INFO_SUFFIX)")
        } else {
            let update = info!.setFolder(folder: folder)
            print("\(self.TAG) Storing info for folder [\(folder)]", update.toString())
            do {
                try UserDefaults.standard.setObj(update, forKey: "\(folder)\(self.INFO_SUFFIX)")
            } catch {
                print("\(self.TAG) Failed to save version info for [\(folder)]", error.localizedDescription)
            }
        }
        UserDefaults.standard.synchronize()
    }

    public func setVersionName(folder: String, versionName: String) {
        print("\(self.TAG) Setting versionName for folder [\(folder)] to \(versionName)")
        let info = self.getVersionInfo(folder: folder)
        self.saveVersionInfo(folder: folder, info: info.setVersionName(versionName: versionName))
    }

    private func setVersionStatus(folder: String, status: VersionStatus) {
        print("\(self.TAG) Setting version status for folder [\(folder)] to \(status)")
        let info = self.getVersionInfo(folder: folder)
        self.saveVersionInfo(folder: folder, info: info.setStatus(status: status.localizedString))
    }

    private func getCurrentBundleFolder() -> String {
        if(self.isUsingBuiltin()) {
            return VersionInfo.VERSION_BUILTIN
        } else {
            let path: String = self.getCurrentBundleFolderName()
            return path.lastPathComponent
        }
    }

    public func getCurrentBundle() -> VersionInfo {
        return self.getVersionInfo(folder: self.getCurrentBundleFolder());
    }

    public func getCurrentBundleFolderName() -> String {
        return UserDefaults.standard.string(forKey: self.CAP_SERVER_PATH) ?? self.DEFAULT_FOLDER
    }

    public func isUsingBuiltin() -> Bool {
        return self.getCurrentBundleFolderName() == self.DEFAULT_FOLDER
    }

    public func getFallbackVersion() -> VersionInfo {
        let folder: String = UserDefaults.standard.string(forKey: self.FALLBACK_VERSION) ?? VersionInfo.VERSION_BUILTIN
        return self.getVersionInfo(folder: folder)
    }

    private func setFallbackVersion(fallback: VersionInfo?) {
        UserDefaults.standard.set(fallback == nil ? VersionInfo.VERSION_BUILTIN : fallback!.getFolder(), forKey: self.FALLBACK_VERSION)
    }

    public func getNextVersion() -> VersionInfo? {
        let folder: String = UserDefaults.standard.string(forKey: self.NEXT_VERSION) ?? ""
        if(folder != "") {
            return self.getVersionInfo(folder: folder)
        } else {
            return nil
        }
    }

    public func setNextVersion(next: String?) -> Bool {
        if (next == nil) {
            UserDefaults.standard.removeObject(forKey: self.NEXT_VERSION)
        } else {
            let bundle: URL = self.getBundleDirectory(folder: next!)
            if (!bundle.exist) {
                return false
            }
            UserDefaults.standard.set(next, forKey: self.NEXT_VERSION)
            self.setVersionStatus(folder: next!, status: VersionStatus.PENDING);
        }
        UserDefaults.standard.synchronize()
        return true
    }
}
