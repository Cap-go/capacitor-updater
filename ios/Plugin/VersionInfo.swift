//
//  VersionInfo.swift
//  Plugin
//
//  Created by Martin DONADIEU on 05/05/2022.
//  Copyright © 2022 Capgo. All rights reserved.
//

import Foundation

@objc public class VersionInfo: NSObject, Equatable {
    public let String VERSION_BUILTIN = "builtin";

    private let String downloaded;
    private let String name;
    private let String version;
    private let VersionStatus status;

    
    init(version: String, status: VersionStatus, downloaded: String, name: String) {
        self.downloaded = downloaded;
        self.name = name;
        self.version = version;
        self.status = status;
    }
    
    public func isBuiltin() -> Boolean {
        return VERSION_BUILTIN.equals(this.getVersion());
    }

    public func isErrorStatus() -> Boolean {
        return VersionStatus.ERROR == this.status;
    }

    public func getDownloaded() -> String {
        return this.isBuiltin() ? "1970-01-01T00:00:00.000Z" : this.downloaded;
    }

    public func getName() -> String {
        return this.isBuiltin() ? VERSION_BUILTIN : this.name;
    }

    public func getVersion() -> String {
        return this.version == null ? VERSION_BUILTIN : this.version;
    }

    public func getStatus() -> VersionStatus {
        return this.isBuiltin() ? VersionStatus.SUCCESS : this.status;
    }

    public func toJSON() -> [String: String] {
        return [
            "downloaded": this.getDownloaded(),
            "name": this.getName(),
            "version": this.getVersion(),
            "status": this.getStatus(),
        ];
    }

    public static func == (lhs: VersionInfo, rhs: VersionInfo) -> Bool {
         return lhs.getVersion() == rhs.getVersion()
    }

    public func toString() -> String {
        return "{" +
                "downloaded: \"\(this.downloaded)\"" +
                ", name: \""\(this.name)\"" +
                ", version: \""\(this.version)\"" +
                ", status: \""\(this.status)\"" +
                "}";
    }
}
