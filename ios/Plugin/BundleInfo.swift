
import Foundation


@objc public class BundleInfo: NSObject, Decodable, Encodable {
    public static let VERSION_BUILTIN: String = "builtin"
    public static let VERSION_UNKNOWN: String = "unknown"
    public static let DOWNLOADED_BUILTIN: String = "1970-01-01T00:00:00.000Z"

    private let downloaded: String
    private let folder: String
    private let version: String
    private let status: BundleStatus
    
    convenience init(folder: String, version: String, status: BundleStatus, downloaded: Date) {
        self.init(folder: folder, version: version, status: status, downloaded: downloaded.iso8601withFractionalSeconds)
    }

    init(folder: String, version: String, status: BundleStatus, downloaded: String = BundleInfo.DOWNLOADED_BUILTIN) {
        self.downloaded = downloaded.trim()
        self.folder = folder
        self.version = version
        self.status = status
    }
    
    enum CodingKeys: String, CodingKey {
        case downloaded, folder, version, status
    }
    
    public func isBuiltin() -> Bool {
        return BundleInfo.VERSION_BUILTIN == self.folder
    }

    public func isUnknown() -> Bool {
        return BundleInfo.VERSION_UNKNOWN == self.folder
    }

    public func isErrorStatus() -> Bool {
        return BundleStatus.ERROR == self.status
    }

    public func isDownloaded() -> Bool {
        return !self.isBuiltin() && self.downloaded != "" && self.downloaded == BundleInfo.DOWNLOADED_BUILTIN
    }

    public func getDownloaded() -> String {
        return self.isBuiltin() ? BundleInfo.DOWNLOADED_BUILTIN : self.downloaded
    }
    
    public func setDownloaded(downloaded: Date) -> BundleInfo {
        return BundleInfo(folder: self.folder, version: self.version, status: self.status, downloaded: downloaded)
    }

    public func getFolder() -> String {
        return self.isBuiltin() ? BundleInfo.VERSION_BUILTIN : self.folder
    }

    public func setFolder(folder: String) -> BundleInfo {
        return BundleInfo(folder: folder, version: self.version, status: self.status, downloaded: self.downloaded)
    }

    public func getVersionName() -> String {
        return self.version == "" ? BundleInfo.VERSION_BUILTIN : self.version
    }

    public func setVersionName(version: String) -> BundleInfo {
        return BundleInfo(folder: self.folder, version: version, status: self.status, downloaded: self.downloaded)
    }

    public func getStatus() -> String {
        return self.isBuiltin() ? BundleStatus.SUCCESS.localizedString : self.status.localizedString
    }

    public func setStatus(status: String) -> BundleInfo {
        return BundleInfo(folder: self.folder, version: self.version, status: BundleStatus(localizedString: status)!, downloaded: self.downloaded)
    }

    public func toJSON() -> [String: String] {
        return [
            "folder": self.getFolder(),
            "version": self.getVersionName(),
            "downloaded": self.getDownloaded(),
            "status": self.getStatus(),
        ]
    }

    public static func == (lhs: BundleInfo, rhs: BundleInfo) -> Bool {
        return lhs.getVersionName() == rhs.getVersionName()
    }

    public func toString() -> String {
        return "{ \"downloaded\": \"\(self.getDownloaded())\", \"folder\": \"\(self.getFolder())\", \"version\": \"\(self.getVersionName())\", \"status\": \"\(self.getStatus())\"}"
    }
}
