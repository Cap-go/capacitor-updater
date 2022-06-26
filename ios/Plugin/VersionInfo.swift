
import Foundation


@objc public class VersionInfo: NSObject, Decodable, Encodable {
    public static let VERSION_BUILTIN: String = "builtin"
    public static let VERSION_UNKNOWN: String = "unknown"
    public static let DOWNLOADED_BUILTIN: String = "1970-01-01T00:00:00.000Z"

    private let downloaded: String
    private let folder: String
    private let versionName: String
    private let status: VersionStatus
    
    convenience init(folder: String, versionName: String, status: VersionStatus, downloaded: Date) {
        self.init(folder: folder, versionName: versionName, status: status, downloaded: downloaded.iso8601withFractionalSeconds)
    }

    init(folder: String, versionName: String, status: VersionStatus, downloaded: String = VersionInfo.DOWNLOADED_BUILTIN) {
        self.downloaded = downloaded.trim()
        self.folder = folder
        self.versionName = versionName
        self.status = status
    }
    
    enum CodingKeys: String, CodingKey {
        case downloaded, folder, versionName, status
    }
    
    public func isBuiltin() -> Bool {
        return VersionInfo.VERSION_BUILTIN == self.folder
    }

    public func isUnknown() -> Bool {
        return VersionInfo.VERSION_UNKNOWN == self.folder
    }

    public func isErrorStatus() -> Bool {
        return VersionStatus.ERROR == self.status
    }

    public func isDownloaded() -> Bool {
        return !self.isBuiltin() && self.downloaded != "" && self.downloaded == VersionInfo.DOWNLOADED_BUILTIN
    }

    public func getDownloaded() -> String {
        return self.isBuiltin() ? VersionInfo.DOWNLOADED_BUILTIN : self.downloaded
    }
    
    public func setDownloaded(downloaded: Date) -> VersionInfo {
        return VersionInfo(folder: self.folder, versionName: self.versionName, status: self.status, downloaded: downloaded)
    }

    public func getFolder() -> String {
        return self.isBuiltin() ? VersionInfo.VERSION_BUILTIN : self.folder
    }

    public func setFolder(folder: String) -> VersionInfo {
        return VersionInfo(folder: folder, versionName: self.versionName, status: self.status, downloaded: self.downloaded)
    }

    public func getVersionName() -> String {
        return self.versionName == "" ? VersionInfo.VERSION_BUILTIN : self.versionName
    }

    public func setVersionName(versionName: String) -> VersionInfo {
        return VersionInfo(folder: self.folder, versionName: versionName, status: self.status, downloaded: self.downloaded)
    }

    public func getStatus() -> String {
        return self.isBuiltin() ? VersionStatus.SUCCESS.localizedString : self.status.localizedString
    }

    public func setStatus(status: String) -> VersionInfo {
        return VersionInfo(folder: self.folder, versionName: self.versionName, status: VersionStatus(localizedString: status)!, downloaded: self.downloaded)
    }

    public func toJSON() -> [String: String] {
        return [
            "folder": self.getFolder(),
            "versionName": self.getVersionName(),
            "downloaded": self.getDownloaded(),
            "status": self.getStatus(),
        ]
    }

    public static func == (lhs: VersionInfo, rhs: VersionInfo) -> Bool {
        return lhs.getVersionName() == rhs.getVersionName()
    }

    public func toString() -> String {
        return "{ \"downloaded\": \"\(self.getDownloaded())\", \"folder\": \"\(self.getFolder())\", \"versionName\": \"\(self.getVersionName())\", \"status\": \"\(self.getStatus())\"}"
    }
}
