//
//  VersionInfo.swift
//  Plugin
//
//  Created by Martin DONADIEU on 05/05/2022.
//  Copyright © 2022 Capgo. All rights reserved.
//

import Foundation
extension String {
    func trim(using characterSet: CharacterSet = .whitespacesAndNewlines) -> String {
        return trimmingCharacters(in: characterSet)
    }
}


@objc public class VersionInfo: NSObject {
    public static let VERSION_BUILTIN: String = "builtin"
    public static let VERSION_UNKNOWN: String = "unknown"
    public static let DOWNLOADED_BUILTIN: String = "1970-01-01T00:00:00.000Z"

    private let downloaded: String
    private let name: String
    private let version: String
    private let status: VersionStatus
    
    convenience init(version: String, status: VersionStatus, downloaded: Date, name: String) {
        self.init(version: version, status: status, downloaded: downloaded.iso8601withFractionalSeconds, name: name)
    }

    init(version: String, status: VersionStatus, downloaded: String, name: String) {
        self.downloaded = downloaded.trim()
        self.name = name
        self.version = version
        self.status = status
    }
    
    public func isBuiltin() -> Bool {
        return VersionInfo.VERSION_BUILTIN == self.getVersion()
    }

    public func isUnknown() -> Bool {
        return VersionInfo.VERSION_UNKNOWN == self.getVersion()
    }

    public func isErrorStatus() -> Bool {
        return VersionStatus.ERROR == self.status
    }

    public func isDownloaded() -> Bool {
        return !self.isBuiltin() && self.downloaded != nil && self.downloaded == VersionInfo.DOWNLOADED_BUILTIN
    }

    public func getDownloaded() -> String {
        return self.isBuiltin() ? VersionInfo.DOWNLOADED_BUILTIN : self.downloaded
    }
    
    public func setDownloaded(downloaded: Date) -> VersionInfo {
        return VersionInfo(version: self.version, status: self.status, downloaded: downloaded, name: self.name)
    }

    public func getName() -> String {
        return self.isBuiltin() ? VersionInfo.VERSION_BUILTIN : self.name
    }

    public func setName(name: String) -> VersionInfo {
        return VersionInfo(version: self.version, status: self.status, downloaded: self.downloaded, name: name)
    }

    public func getVersion() -> String {
        return self.version == nil ? VersionInfo.VERSION_BUILTIN : self.version
    }

    public func setVersion(version: String) -> VersionInfo {
        return VersionInfo(version: version, status: self.status, downloaded: self.downloaded, name: self.name)
    }

    public func getStatus() -> VersionStatus {
        return self.isBuiltin() ? VersionStatus.SUCCESS : self.status
    }

    public func setStatus(status: VersionStatus) -> VersionInfo {
        return VersionInfo(version: self.version, status: status, downloaded: self.downloaded, name: self.name)
    }

    public func toJSON() -> [String: String] {
        return [
            "downloaded": self.getDownloaded(),
            "name": self.getName(),
            "version": self.getVersion(),
            "status": self.getStatus().localizedString,
        ]
    }

    public static func == (lhs: VersionInfo, rhs: VersionInfo) -> Bool {
        return lhs.getVersion() == rhs.getVersion()
    }

    public func toString() -> String {
        return "{ downloaded: \"\(self.downloaded)\", name: \"\(self.name)\", version: \"\(self.version)\", status: \"\(self.status)\"}"
    }
}
