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
    
    public func addPath(_ path: URL) {
        self.lock.locked {
            self.storagePathList.append(path)
        }
    }
    
    public func removeFilepathByBase(_ base: String) {
        self.lock.locked {
            self.storagePathList = self.storagePathList.filter {
                !$0.absoluteString.starts(with: base)
            }
        }
    }
    
    // This fn will check if all storagePathList actually exist
    // If not then it will remove them and retun true
    // If true returned ManifestStorage.saveToDeviceStorage should be called
    public func cleanupFilePaths() -> Bool {
        if (self.type == .builtin) {
            return false
        }
        
        return self.lock.locked {
            var startLen = storagePathList.count
            self.storagePathList = self.storagePathList.filter {
                $0.exist
            }
            var endLen = storagePathList.count
            return endLen == startLen
        }
    }
    
    // We DO NOT want to encode the lock.
    // This enum means that lock will be skipped during encoding
    private enum CodingKeys: String, CodingKey {
        case hash, type, storagePathList
    }
}
