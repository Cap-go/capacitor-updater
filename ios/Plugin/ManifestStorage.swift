//
//  ManifestStorage.swift
//  CapgoCapacitorUpdater
//
//  Created by Michał Trembaly on 30/03/2024.
//

import Foundation

class ManifestStorage {
    func recusiveAssetFolderLoad(_ bundle: Bundle, folder: String) throws -> [URL]  {
        guard let files = bundle.urls(forResourcesWithExtension: nil, subdirectory: folder) else {
            throw NSError(domain: "Failed to get the files from folder \(folder)", code: 5, userInfo: nil)
        }
        
        var finalFiles = [URL]()
        for file in files {
            if (file.isDirectory) {
                guard let finalPathComponent = file.pathComponents.last else {
                    throw NSError(domain: "Failed to get the finalPathComponent from folder \(folder) + \(file.absoluteString)", code: 5, userInfo: nil)
                }
                
                finalFiles.append(contentsOf: try recusiveAssetFolderLoad(bundle, folder: folder + "/" + finalPathComponent))
            } else {
                finalFiles.append(file)
            }
        }
        
        return finalFiles
    }
}
