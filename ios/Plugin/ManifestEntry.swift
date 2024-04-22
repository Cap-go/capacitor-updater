//
//  ManifestEntry.swift
//  CapgoCapacitorUpdater
//
//  Created by Michał Trembaly on 31/03/2024.
//

import Foundation

enum ManifestEntryType: Codable {
    case builtin, url
}

public class ManifestEntry: Codable {
    private var storagePathList = [URL]()
    // This lock is swift specific, swift does not have synchronized as java has. It's required to ensure thread safety
    private var lock = UnfairLock()
    let hash: String
    let type: ManifestEntryType
    
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
    
    public func copyUrl() -> URL? {
        return self.storagePathList.first
    }
    
    public func copy() -> ManifestEntry {
        return ManifestEntry(storagePathList: self.storagePathList.map { URL(string: $0.absoluteString)! }, hash: self.hash, type: self.type)
    }
    
    // We DO NOT want to encode the lock.
    // This enum means that lock will be skipped during encoding
    private enum CodingKeys: String, CodingKey {
        case hash, type, storagePathList
    }
}
