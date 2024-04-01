//
//  ManifestEntry.swift
//  CapgoCapacitorUpdater
//
//  Created by Michał Trembaly on 31/03/2024.
//

import Foundation

enum ManifestEntryType {
    case builtin, url
}

public class ManifestEntry {
    private var storagePathList = [URL]()
    let hash: String
    private let type: ManifestEntryType
    
    init(filePath: URL, hash: String, type: ManifestEntryType) {
        self.storagePathList.append(filePath)
        self.type = type
        self.hash = hash
    }
    
    private init(storagePathList: [URL], hash: String, type: ManifestEntryType) {
        self.storagePathList = storagePathList
        self.type = type
        self.hash = hash
    }
    
    public func copy() -> ManifestEntry {
        return ManifestEntry(storagePathList: self.storagePathList.map { URL(string: $0.absoluteString)! }, hash: self.hash, type: self.type)
    }
}
