//
//  ManifestStorage.swift
//  CapgoCapacitorUpdater
//
//  Created by Michał Trembaly on 30/03/2024.
//

import Foundation
import CommonCrypto

extension Data{
    public func sha256() -> String{
        return hexStringFromData(input: digest(input: self as NSData))
    }
    
    private func digest(input : NSData) -> NSData {
        let digestLength = Int(CC_SHA256_DIGEST_LENGTH)
        var hash = [UInt8](repeating: 0, count: digestLength)
        CC_SHA256(input.bytes, UInt32(input.length), &hash)
        return NSData(bytes: hash, length: digestLength)
    }
    
    private  func hexStringFromData(input: NSData) -> String {
        var bytes = [UInt8](repeating: 0, count: input.length)
        input.getBytes(&bytes, length: input.length)
        
        var hexString = ""
        for byte in bytes {
            hexString += String(format:"%02x", UInt8(byte))
        }
        
        return hexString
    }
}

public protocol LockedManifestStorage {
    func getEntryByHash(hash: String) -> ManifestEntry?
    func getEntries() -> [String: ManifestEntry]
}

//internal class LockedManifestStorageImpl: LockedManifestStorage {
//    let storage: ManifestStorage
//    
//    init(storage: ManifestStorage) {
//        self.storage = storage
//    }
//    
//    func getEntryByHash(hash: String) -> ManifestEntry? {
//        return self.storage.manifestHashMap[hash]
//    }
//    
//    func getEntries() -> [String: ManifestEntry] {
//        return self.storage.manifestHashMap
//    }
//}

public class ManifestStorage {
    
    // Swift specific
    private let TAG = "✨  Capacitor-updater:"
    private let cachePreferencesKey = "CapgoDownloadedManifestJson"
    private let lock = UnfairLock()
    
    // Shared (ios <-> android)
    // internal var manifestHashMap: [String: ManifestEntry] = [:]
    
    lazy var cache: Cache<String, ManifestEntry> = {
        guard let savedCache = UserDefaults.standard.string(forKey: self.cachePreferencesKey) else {
            return Cache<String, ManifestEntry>()
        }
        
        do {
            let decodedCache = try JSONDecoder().decode(Cache<String, ManifestEntry>.self, from: Data(savedCache.utf8))
            return decodedCache
        } catch {
            print("\(self.TAG) Cannot load the saved manifes storage manifest, error: \(error)")
            return Cache<String, ManifestEntry>()
        }
    }()
    
    private func recusiveAssetFolderLoad(_ bundle: Bundle, folder: String) throws -> [URL]  {
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
    
    private func loadBuiltinManifest() -> [ManifestEntry]? {
        do {
            let allFiles = try recusiveAssetFolderLoad(Bundle.main, folder: "public")
            var manifestEntries = [ManifestEntry]()
            manifestEntries.reserveCapacity(allFiles.count)
            
            for file in allFiles {
                let data = try Data(contentsOf: file)
                let hash = data.sha256()
                manifestEntries.append(ManifestEntry(filePath: file, hash: hash, type: ManifestEntryType.builtin))
            }
            
            return manifestEntries
        } catch {
            print("\(self.TAG) Cannot load the builtin manifest, error: \(error)")
            return nil;
        }
    }
    
    // Init in android
    func initialize() {
        // TODO: remove this debug
        // UserDefaults.standard.removeObject(forKey: cachePreferencesKey)
        // UserDefaults.standard.synchronize()

        
        guard let buildIn = loadBuiltinManifest() else {
            // Logging is done in loadBuiltinManifest, safe to just return
            return
        }
        
        // Add to the cache
        buildIn.forEach {
            self.cache[$0.hash] = $0
        }
        
        // Lock to prevent concurrent manifestHashMap access
//        self.lock.locked() {
//            for entry in buildIn {
//                self.manifestHashMap[entry.hash] = entry
//            }
//        }
    }
    
//    func locked<ReturnValue>(_ f: (_ storage: LockedManifestStorage) throws -> ReturnValue) rethrows -> ReturnValue {
//        try self.lock.locked {
//            try f(LockedManifestStorageImpl(storage: self))
//        }
//    }
    
    func saveToDeviceStorage() {
        // We don't quite have "synchronized" in swift, we have to use this lock
        
        do {
            try self.lock.locked {
                // It's important to note that in android we apply a filter to make sure  that ManifestEntryType = ManifestEntry.ManifestEntryType.BUILTIN
                // Here we DO NOT. This filter is part of the internal impl of cache. This does suck but it does work
                guard let encodedCache = String(data: (try JSONEncoder().encode(self.cache)), encoding: .utf8) else {
                    print("\(self.TAG) Cannot get the encoded cache for manifest storage")
                    return
                }
                
                UserDefaults.standard.set(encodedCache, forKey: cachePreferencesKey)
                UserDefaults.standard.synchronize()
            }
        } catch {
            print("\(self.TAG) Cannot save manifest storage into device storage. Error: \(error.localizedDescription)")
        }
    }
}
