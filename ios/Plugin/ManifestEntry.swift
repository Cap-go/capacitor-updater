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
}
