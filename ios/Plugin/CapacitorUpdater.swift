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
    var iso8601withFractionalSeconds: Date? { return Formatter.iso8601withFractionalSeconds.date(from: self) }
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
        case .cannotUnzip:
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
    private let bundleDirectory = "NoCloud/ionic_built_snapshots"
    private let DOWNLOADED_SUFFIX = "_downloaded"
    private let NAME_SUFFIX = "_name"
    private let STATUS_SUFFIX = "_status"
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
    
    public var notifyDownload: (Int) -> Void = { _ in }

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
    
    private func prepareFolder(source: URL) {
        if (!FileManager.default.fileExists(atPath: source.path)) {
            do {
                try FileManager.default.createDirectory(atPath: source.path, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("\(self.TAG) Cannot createDirectory \(source.path)")
                throw CustomError.cannotCreateDirectory
            }
        }
    }
    
    private func deleteFolder(source: URL) {
        do {
            try FileManager.default.removeItem(atPath: source.path)
        } catch {
            print("\(self.TAG) File not removed. \(source.path)")
            throw CustomError.cannotDeleteDirectory
        }
    }
    
    private func unflatFolder(source: URL, dest: URL) -> Bool {
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
    
    private func saveDownloaded(sourceZip: URL, version: String, base: URL) throws {
        prepareFolder(source: base)
        let destHot = base.appendingPathComponent(version)
        let destUnZip = documentsDir.appendingPathComponent(randomString(length: 10))
        if (!SSZipArchive.unzipFile(atPath: sourceZip.path, toDestination: destUnZip.path)) {
            throw CustomError.cannotUnzip
        }
        if (unflatFolder(source: destUnZip, dest: destHot)) {
            deleteFolder(source: destUnZip)
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
            "cap_version_name": UserDefaults.standard.string(forKey: "versionName") ?? "builtin"
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
        print("\(self.TAG) Current bundle set to: \(source.path) dest: \(dest.path)")
        UserDefaults.standard.synchronize()
    }

    public func download(url: URL, versionName: String) throws -> VersionInfo {
        let semaphore = DispatchSemaphore(value: 0)
        var version: String = ""
        var mainError: NSError? = nil
        let destination: DownloadRequest.Destination = { _, _ in
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileURL = documentsURL.appendingPathComponent(self.randomString(length: 10))

            return (fileURL, [.removePreviousFile, .createIntermediateDirectories])
        }
        let request = AF.download(url, to: destination)
        
        request.downloadProgress { progress in
            let percent = self.calcTotalPercent(percent: Int(progress.fractionCompleted * 100), min: 10, max: 70)
            self.notifyDownload(percent)
        }
        request.responseURL { (response) in
            if let fileURL = response.fileURL {
                switch response.result {
                case .success:
                    self.notifyDownload(71);
                    version = self.randomString(length: 10)
                    do {
                        try self.saveDownloaded(sourceZip: fileURL, version: version, base: self.documentsDir.appendingPathComponent(self.bundleDirectoryHot))
                        self.notifyDownload(85)
                        try self.saveDownloaded(sourceZip: fileURL, version: version, base: self.libraryDir.appendingPathComponent(self.bundleDirectory))
                        self.notifyDownload(100)
                        self.deleteFolder(source: fileURL)
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
        self.notifyDownload(0)
        semaphore.wait()
        if (mainError != nil) {
            throw mainError!
        }
        self.setVersionStatus(version, VersionStatus.PENDING)
        self.setVersionDownloadedTimestamp(version, Date())
        self.setVersionName(version, versionName)
        return self.getVersionInfo(version)
    }

    public func list() -> [String] {
        let dest = documentsDir.appendingPathComponent(bundleDirectoryHot)
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: dest.path)
            return files
        } catch {
            print("\(self.TAG) No version available \(dest.path)")
            return []
        }
    }
    
    public func delete(version: String, versionName: String) -> Bool {
        let destHot = documentsDir.appendingPathComponent(bundleDirectoryHot).appendingPathComponent(version)
        let destPersist = libraryDir.appendingPathComponent(bundleDirectory).appendingPathComponent(version)
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
        sendStats(action: "delete", version: versionName)
        return true
    }

    public func set(version: String, versionName: String) -> Bool {
        let destHot = documentsDir.appendingPathComponent(bundleDirectoryHot).appendingPathComponent(version)
        let indexHot = destHot.appendingPathComponent("index.html")
        let destHotPersist = libraryDir.appendingPathComponent(bundleDirectory).appendingPathComponent(version)
        let indexPersist = destHotPersist.appendingPathComponent("index.html")
        if (destHot.isDirectory && destHotPersist.isDirectory && indexHot.exist && indexPersist.exist) {
            UserDefaults.standard.set(destHot.path, forKey: "lastPathHot")
            UserDefaults.standard.set(destHotPersist.path, forKey: "lastPathPersist")
            UserDefaults.standard.set(versionName, forKey: "versionName")
            sendStats(action: "set", version: versionName)
            return true
        }
        sendStats(action: "set_fail", version: versionName)
        return false
    }
    
    public func getLastPathHot() -> String {
        return UserDefaults.standard.string(forKey: "lastPathHot") ?? ""
    }
    
    public func getVersionName() -> String {
        return UserDefaults.standard.string(forKey: "versionName") ?? ""
    }
    
    public func getLastPathPersist() -> String {
        return UserDefaults.standard.string(forKey: "lastPathPersist") ?? ""
    }
    
    public func reset() {
        let version = UserDefaults.standard.string(forKey: "versionName") ?? ""
        sendStats(action: "reset", version: version)
        UserDefaults.standard.set("", forKey: "lastPathHot")
        UserDefaults.standard.set("", forKey: "lastPathPersist")
        UserDefaults.standard.set("", forKey: "versionName")
        UserDefaults.standard.synchronize()
    }

    func sendStats(action: String, version: String) {
        if (statsUrl == "") { return }
        let parameters: [String: String] = [
            "platform": "ios",
            "action": action,
            "device_id": self.deviceID,
            "version_name": version,
            "version_build": self.versionBuild,
            "version_code": self.versionCode,
            "version_os": self.versionOs,
            "plugin_version": self.pluginVersion,
            "app_id": self.appId
        ]

        DispatchQueue.global(qos: .background).async {
            let _ = AF.request(self.statsUrl, method: .post,parameters: parameters, encoder: JSONParameterEncoder.default)
            print("\(self.TAG) Stats send for \(action), version \(version)")
        }
    }

    public func getVersionInfo(version:? String) -> VersionInfo {
        if(version == nil) {
            version = "unknown"
        }
        let downloaded: String = self.getVersionDownloadedTimestamp(version)
        let name: String = self.getVersionName(version)
        final VersionStatus status = self.getVersionStatus(version)
        return new VersionInfo(version, status, downloaded, name)
    }

    public func getVersionInfoByName(version: String) -> VersionInfo? {
        let installed : Array<VersionInfo> = self.list()
        for i in installed {
            if(i.getName() == version) {
                return i
            }
        }
        return nil
    }

    private func removeVersionInfo(version: String) {
        self.setVersionDownloadedTimestamp(version, nil)
        self.setVersionName(version, nil)
        self.setVersionStatus(version, nil)
    }

    private func getVersionDownloadedTimestamp(version: String) -> String {
        return UserDefaults.standard.string(forKey: "\(version)\(self.DOWNLOADED_SUFFIX)")  ?? ""
    }

    private func setVersionDownloadedTimestamp(version:? String, time:? Date) {
        if(version != nil) {
            print("\(self.TAG) Setting version download timestamp \(version) to \(time)")
            if(time == nil) {
                UserDefaults.standard.removeObject(forKey: "\(version)\(self.DOWNLOADED_SUFFIX)")
            } else {
                let isoDate = time.iso8601withFractionalSeconds  
                UserDefaults.standard.set(isoDate, forKey: "\(version)\(self.DOWNLOADED_SUFFIX)")
            }
            UserDefaults.standard.synchronize()
        }
    }

    private func getVersionName(version: String) -> String {
        return UserDefaults.standard.string(forKey: "\(version)\(self.NAME_SUFFIX)") ?? ""
    }

    public func setVersionName(version:? String, name:? String) {
        if(version != nil) {
            print("\(self.TAG) Setting version name \(version) to \(time)")
            if(name == nil) {
                UserDefaults.standard.removeObject(forKey: "\(version)\(self.NAME_SUFFIX)")
            } else {
                UserDefaults.standard.set(name, forKey: "\(version)\(self.NAME_SUFFIX)")
            }
            UserDefaults.standard.synchronize()
        }
    }

    private func getVersionStatus(version: String) -> VersionStatus {
        let status = UserDefaults.standard.string(forKey: "\(version)\(self.STATUS_SUFFIX)") ?? "pending"
        return VersionStatus.fromString(status)
    }

    private func setVersionStatus(version:? String, status:? VersionStatus) {
        if(version != nil) {
            print("\(self.TAG) Setting version status \(version) to \(status)")
            if(status == nil) {
                UserDefaults.standard.removeObject(forKey: "\(version)\(self.STATUS_SUFFIX)")
            } else {
                UserDefaults.standard.set(status.toString(), forKey: "\(version)\(self.STATUS_SUFFIX)")
            }
            UserDefaults.standard.synchronize()
        }
    }

    private func getCurrentBundleVersion() -> String {
        if(self.isUsingBuiltin()) {
            return VersionInfo.VERSION_BUILTIN
        } else {
            let path: String = self.getCurrentBundlePath()
            return path.substring(from: path.lastIndex(of: "/") + 1)
        }
    }

    public func getCurrentBundle() -> VersionInfo {
        return self.getVersionInfo(self.getCurrentBundleVersion());
    }

    public func getCurrentBundlePath() -> String {
        return UserDefaults.standard.string(forKey: self.CAP_SERVER_PATH) ?? "public"
    }

    public func isUsingBuiltin() -> Boolean {
        return self.getCurrentBundlePath().equals("public")
    }

    public func getFallbackVersion() -> VersionInfo {
        let version: String = UserDefaults.standard.string(forKey: self.FALLBACK_VERSION) ?? VersionInfo.VERSION_BUILTIN
        return self.getVersionInfo(version)
    }

    private func setFallbackVersion(fallback:? VersionInfo ) {
        UserDefaults.standard.set(fallback == nil ? VersionInfo.VERSION_BUILTIN : fallback.getVersion(), forKey: self.FALLBACK_VERSION)
    }

    public func getNextVersion() -> VersionInfo? {
        let version: String = UserDefaults.standard.string(forKey: self.NEXT_VERSION) ?? ""
        if(version != "") {
            return self.getVersionInfo(version)
        } else {
            return nil
        }
    }

    public func setNextVersion(next:? String) -> boolean {
        if (next == nil) {
            UserDefaults.standard.removeObject(forKey: self.NEXT_VERSION)
        } else {
            let bundle: File = self.getBundle(next!)
            if (!self.bundleExists(bundle)) {
                return false
            }
            UserDefaults.standard.set(next, forKey: self.NEXT_VERSION)
            self.setVersionStatus(next, VersionStatus.PENDING);
        }
        UserDefaults.standard.synchronize()
        return true
    }
    
}
