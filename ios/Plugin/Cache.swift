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
        // This is pure stupid, i HATE this with ALL of my heart.
        // Please, please, find a better way for this
        // This lock is the stupidest thing
        internal var lock = UnfairLock()

        func cache(_ cache: NSCache<AnyObject, AnyObject>,
                   willEvictObject object: Any) {
            guard let entry = object as? Entry else {
                return
            }
            
            // Ignore the result
            let _ = lock.locked {
                keys.remove(entry.key)
            }
        }
        
        func addKey(_ key: Key) {
            // Ignore the result
            let _ = lock.locked {
                keys.insert(key)
            }
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
        
        var toEncode = keyTracker.lock.locked {
            keyTracker.keys.compactMap(entry).filter {
                // It;s hacky but it SHOULD work.
                // I don't encode the ManifestEntry where type = builtin
                // This is by design - i don't want them as we will ALWAYS generate them dynamicly
                guard let value = $0.value as? ManifestEntry else {
                    return true
                }
                
                return value.type != .builtin
            }
        }
        
        try container.encode(toEncode)
    }
}

extension Cache.Entry: Codable where Key: Codable, Value: Codable {}

final class Cache<Key: Hashable, Value> {
    private let wrapped = NSCache<WrappedKey, Entry>()
    private let keyTracker = KeyTracker()

    
    func insert(_ value: Value, forKey key: Key) {
        let entry = Entry(key: key, value: value)
        keyTracker.addKey(key)
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
    
    func forEach(_ f: (_ entry: Value) throws -> ()) throws {
        try self.keyTracker.lock.locked {
            try self.keyTracker.keys.forEach {
                guard let entry = self.entry(forKey: $0) else {
                    throw NSError(domain: "Failed to get the value for key \($0). Very invalid - should NEVER happen", code: 5, userInfo: nil)
                }

                try f(entry.value)
            }
        }
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
