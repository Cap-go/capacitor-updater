/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation

@objc public class BundleInfo: NSObject, Decodable, Encodable {
    public static let ID_BUILTIN: String = "builtin"
    public static let VERSION_UNKNOWN: String = "unknown"
    public static let DOWNLOADED_BUILTIN: String = "1970-01-01T00:00:00.000Z"

    private let downloaded: String
    private let id: String
    private let version: String
    private let checksum: String
    private let status: BundleStatus
    private let link: String?
    private let comment: String?

    convenience init(id: String, version: String, status: BundleStatus, downloaded: Date, checksum: String, link: String? = nil, comment: String? = nil) {
        self.init(id: id, version: version, status: status, downloaded: downloaded.iso8601withFractionalSeconds, checksum: checksum, link: link, comment: comment)
    }

    init(id: String, version: String, status: BundleStatus, downloaded: String = BundleInfo.DOWNLOADED_BUILTIN, checksum: String, link: String? = nil, comment: String? = nil) {
        self.downloaded = downloaded.trim()
        self.id = id
        self.version = version
        self.checksum = checksum
        self.status = status
        self.link = link
        self.comment = comment
    }

    enum CodingKeys: String, CodingKey {
        case downloaded, id, version, status, checksum, link, comment
    }

    public func isBuiltin() -> Bool {
        return BundleInfo.ID_BUILTIN == self.id
    }

    public func isUnknown() -> Bool {
        return BundleInfo.VERSION_UNKNOWN == self.id
    }

    public func isErrorStatus() -> Bool {
        return BundleStatus.ERROR == self.status
    }

    public func isDeleted() -> Bool {
        return BundleStatus.DELETED == self.status
    }

    public func isDownloaded() -> Bool {
        return !self.isBuiltin() && self.downloaded != "" && self.downloaded != BundleInfo.DOWNLOADED_BUILTIN && !self.isDeleted()
    }

    public func getDownloaded() -> String {
        return self.isBuiltin() ? BundleInfo.DOWNLOADED_BUILTIN : self.downloaded
    }

    public func getChecksum() -> String {
        return self.isBuiltin() ? "" : self.checksum
    }

    public func setChecksum(checksum: String) -> BundleInfo {
        return BundleInfo(id: self.id, version: self.version, status: self.status, downloaded: self.downloaded, checksum: checksum, link: self.link, comment: self.comment)
    }

    public func setDownloaded(downloaded: Date) -> BundleInfo {
        return BundleInfo(id: self.id, version: self.version, status: self.status, downloaded: downloaded, checksum: self.checksum, link: self.link, comment: self.comment)
    }

    public func getId() -> String {
        return self.isBuiltin() ? BundleInfo.ID_BUILTIN : self.id
    }

    public func setId(id: String) -> BundleInfo {
        return BundleInfo(id: id, version: self.version, status: self.status, downloaded: self.downloaded, checksum: self.checksum, link: self.link, comment: self.comment)
    }

    public func getVersionName() -> String {
        return self.version.isEmpty ? BundleInfo.ID_BUILTIN : self.version
    }

    public func setVersionName(version: String) -> BundleInfo {
        return BundleInfo(id: self.id, version: version, status: self.status, downloaded: self.downloaded, checksum: self.checksum, link: self.link, comment: self.comment)
    }

    public func getStatus() -> String {
        return self.isBuiltin() ? BundleStatus.SUCCESS.localizedString : self.status.localizedString
    }

    public func setStatus(status: String) -> BundleInfo {
        return BundleInfo(id: self.id, version: self.version, status: BundleStatus(localizedString: status)!, downloaded: self.downloaded, checksum: self.checksum, link: self.link, comment: self.comment)
    }

    public func getLink() -> String? {
        return self.link
    }

    public func setLink(link: String?) -> BundleInfo {
        return BundleInfo(id: self.id, version: self.version, status: self.status, downloaded: self.downloaded, checksum: self.checksum, link: link, comment: self.comment)
    }

    public func getComment() -> String? {
        return self.comment
    }

    public func setComment(comment: String?) -> BundleInfo {
        return BundleInfo(id: self.id, version: self.version, status: self.status, downloaded: self.downloaded, checksum: self.checksum, link: self.link, comment: comment)
    }

    public func toJSON() -> [String: String] {
        var result: [String: String] = [
            "id": self.getId(),
            "version": self.getVersionName(),
            "downloaded": self.getDownloaded(),
            "checksum": self.getChecksum(),
            "status": self.getStatus()
        ]
        if let link = self.link {
            result["link"] = link
        }
        if let comment = self.comment {
            result["comment"] = comment
        }
        return result
    }

    public static func == (lhs: BundleInfo, rhs: BundleInfo) -> Bool {
        return lhs.getVersionName() == rhs.getVersionName()
    }

    public func toString() -> String {
        return "{ \"id\": \"\(self.getId())\", \"version\": \"\(self.getVersionName())\", \"downloaded\": \"\(self.getDownloaded())\", \"checksum\": \"\(self.getChecksum())\", \"status\": \"\(self.getStatus())\"}"
    }
}
