//
//  Cache.swift
//  CapgoCapacitorUpdater
//
//  Created by Michał Trembaly on 18/04/2024.
//

// This file is inspired on this article:
// https://www.swiftbysundell.com/articles/caching-in-swift/

import Foundation

private extension Cache {
    final class WrappedKey: NSObject {
        let key: Key

        init(_ key: Key) { self.key = key }

        override var hash: Int { return key.hashValue }

        override func isEqual(_ object: Any?) -> Bool {
            guard let value = object as? WrappedKey else {
                return false
            }

            return value.key == key
        }
    }
    
    final class Entry {
        let value: Value
        let key: Key
        
        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }
    
    final class KeyTracker: NSObject, NSCacheDelegate {
        var keys = Set<Key>()

        func cache(_ cache: NSCache<AnyObject, AnyObject>,
                   willEvictObject object: Any) {
            guard let entry = object as? Entry else {
                return
            }

            keys.remove(entry.key)
        }
    }
}

extension Cache {
    subscript(key: Key) -> Value? {
        get { return value(forKey: key) }
        set {
            guard let value = newValue else {
                // If nil was assigned using our subscript,
                // then we remove any value for that key:
                removeValue(forKey: key)
                return
            }

            insert(value, forKey: key)
        }
    }
}

extension Cache: Codable where Key: Codable, Value: Codable {
    convenience init(from decoder: Decoder) throws {
        self.init()

        let container = try decoder.singleValueContainer()
        let entries = try container.decode([Entry].self)
        entries.forEach(insert)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        try container.encode(keyTracker.keys.compactMap(entry).filter {
            // It;s hacky but it SHOULD work.
            // I don't encode the ManifestEntry where type = builtin
            // This is by design - i don't want them as we will ALWAYS generate them dynamicly
            guard let value = $0.value as? ManifestEntry else {
                return true
            }
            
            return value.type != .builtin
        })
    }
}

extension Cache.Entry: Codable where Key: Codable, Value: Codable {}

final class Cache<Key: Hashable, Value> {
    private let wrapped = NSCache<WrappedKey, Entry>()
    private let keyTracker = KeyTracker()

    
    func insert(_ value: Value, forKey key: Key) {
        let entry = Entry(key: key, value: value)
        keyTracker.keys.insert(key)
        wrapped.setObject(entry, forKey: WrappedKey(key))
    }

    func value(forKey key: Key) -> Value? {
        let entry = wrapped.object(forKey: WrappedKey(key))
        return entry?.value
    }

    func removeValue(forKey key: Key) {
        wrapped.removeObject(forKey: WrappedKey(key))
    }
    
    private func entry(forKey key: Key) -> Entry? {
        guard let entry = wrapped.object(forKey: WrappedKey(key)) else {
            return nil
        }

        return entry
    }

    private func insert(_ entry: Entry) {
        wrapped.setObject(entry, forKey: WrappedKey(entry.key))
        keyTracker.keys.insert(entry.key)
    }

    
    init() {
        // Here is where we branch off this article
        // We will configure NSCache to be persisent (to never remove keys)
        // This is really important
        wrapped.evictsObjectsWithDiscardedContent = false
        wrapped.countLimit = 0
        wrapped.totalCostLimit = 0
        wrapped.delegate = keyTracker
    }
}
