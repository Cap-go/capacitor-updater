
import Foundation


@objc public class BundleInfo: NSObject, Decodable, Encodable {
    public static let VERSION_BUILTIN: String = "builtin"
    public static let VERSION_UNKNOWN: String = "unknown"
    public static let DOWNLOADED_BUILTIN: String = "1970-01-01T00:00:00.000Z"

    private let downloaded: String
    private let id: String
    private let version: String
    private let status: BundleStatus
    
    convenience init(id: String, version: String, status: BundleStatus, downloaded: Date) {
        self.init(id: id, version: version, status: status, downloaded: downloaded.iso8601withFractionalSeconds)
    }

    init(id: String, version: String, status: BundleStatus, downloaded: String = BundleInfo.DOWNLOADED_BUILTIN) {
        self.downloaded = downloaded.trim()
        self.id = id
        self.version = version
        self.status = status
    }
    
    enum CodingKeys: String, CodingKey {
        case downloaded, id, version, status
    }
    
    public func isBuiltin() -> Bool {
        return BundleInfo.VERSION_BUILTIN == self.id
    }

    public func isUnknown() -> Bool {
        return BundleInfo.VERSION_UNKNOWN == self.id
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
        return BundleInfo(id: self.id, version: self.version, status: self.status, downloaded: downloaded)
    }

    public func getId() -> String {
        return self.isBuiltin() ? BundleInfo.VERSION_BUILTIN : self.id
    }

    public func setId(id: String) -> BundleInfo {
        return BundleInfo(id: id, version: self.version, status: self.status, downloaded: self.downloaded)
    }

    public func getVersionName() -> String {
        return self.version == "" ? BundleInfo.VERSION_BUILTIN : self.version
    }

    public func setVersionName(version: String) -> BundleInfo {
        return BundleInfo(id: self.id, version: version, status: self.status, downloaded: self.downloaded)
    }

    public func getStatus() -> String {
        return self.isBuiltin() ? BundleStatus.SUCCESS.localizedString : self.status.localizedString
    }

    public func setStatus(status: String) -> BundleInfo {
        return BundleInfo(id: self.id, version: self.version, status: BundleStatus(localizedString: status)!, downloaded: self.downloaded)
    }

    public func toJSON() -> [String: String] {
        return [
            "id": self.getId(),
            "version": self.getVersionName(),
            "downloaded": self.getDownloaded(),
            "status": self.getStatus(),
        ]
    }

    public static func == (lhs: BundleInfo, rhs: BundleInfo) -> Bool {
        return lhs.getVersionName() == rhs.getVersionName()
    }

    public func toString() -> String {
        return "{ \"downloaded\": \"\(self.getDownloaded())\", \"id\": \"\(self.getId())\", \"version\": \"\(self.getVersionName())\", \"status\": \"\(self.getStatus())\"}"
    }
}
