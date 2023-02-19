import Foundation

@objc public class BundleInfo: NSObject, Decodable, Encodable {
    public static let idBuiltin: String = "builtin"
    public static let versionUnknown: String = "unknown"
    public static let downloadedBuiltin: String = "1970-01-01T00:00:00.000Z"

    private let downloaded: String
    private let id: String
    private let version: String
    private let checksum: String
    private let status: BundleStatus

    convenience init(id: String, version: String, status: BundleStatus, downloaded: Date, checksum: String) {
        self.init(id: id, version: version, status: status, downloaded: downloaded.iso8601withFractionalSeconds, checksum: checksum)
    }

    init(id: String, version: String, status: BundleStatus, downloaded: String = BundleInfo.downloadedBuiltin, checksum: String) {
        self.downloaded = downloaded.trim()
        self.id = id
        self.version = version
        self.checksum = checksum
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case downloaded, id, version, status, checksum
    }

    public func isBuiltin() -> Bool {
        return BundleInfo.idBuiltin == self.id
    }

    public func isUnknown() -> Bool {
        return BundleInfo.versionUnknown == self.id
    }

    public func isErrorStatus() -> Bool {
        return BundleStatus.ERROR == self.status
    }

    public func isDeleted() -> Bool {
        return BundleStatus.DELETED == self.status
    }

    public func isDownloaded() -> Bool {
        return !self.isBuiltin() && self.downloaded != "" && self.downloaded != BundleInfo.downloadedBuiltin && !self.isDeleted()
    }

    public func getDownloaded() -> String {
        return self.isBuiltin() ? BundleInfo.downloadedBuiltin : self.downloaded
    }

    public func getChecksum() -> String {
        return self.isBuiltin() ? "" : self.checksum
    }

    public func setChecksum(checksum: String) -> BundleInfo {
        return BundleInfo(id: self.id, version: self.version, status: self.status, downloaded: self.downloaded, checksum: checksum)
    }

    public func setDownloaded(downloaded: Date) -> BundleInfo {
        return BundleInfo(id: self.id, version: self.version, status: self.status, downloaded: downloaded, checksum: self.checksum)
    }

    public func getId() -> String {
        return self.isBuiltin() ? BundleInfo.idBuiltin : self.id
    }

    public func setId(id: String) -> BundleInfo {
        return BundleInfo(id: id, version: self.version, status: self.status, downloaded: self.downloaded, checksum: self.checksum)
    }

    public func getVersionName() -> String {
        return (self.version ?? "").isEmpty ? BundleInfo.idBuiltin : self.version
    }

    public func setVersionName(version: String) -> BundleInfo {
        return BundleInfo(id: self.id, version: version, status: self.status, downloaded: self.downloaded, checksum: self.checksum)
    }

    public func getStatus() -> String {
        return self.isBuiltin() ? BundleStatus.SUCCESS.localizedString : self.status.localizedString
    }

    public func setStatus(status: String) -> BundleInfo {
        return BundleInfo(id: self.id, version: self.version, status: BundleStatus(localizedString: status)!, downloaded: self.downloaded, checksum: self.checksum)
    }

    public func toJSON() -> [String: String] {
        return [
            "id": self.getId(),
            "version": self.getVersionName(),
            "downloaded": self.getDownloaded(),
            "checksum": self.getChecksum(),
            "status": self.getStatus()
        ]
    }

    public static func == (lhs: BundleInfo, rhs: BundleInfo) -> Bool {
        return lhs.getVersionName() == rhs.getVersionName()
    }

    public func toString() -> String {
        return "{ \"id\": \"\(self.getId())\", \"version\": \"\(self.getVersionName())\", \"downloaded\": \"\(self.getDownloaded())\", \"checksum\": \"\(self.getChecksum())\", \"status\": \"\(self.getStatus())\"}"
    }
}
