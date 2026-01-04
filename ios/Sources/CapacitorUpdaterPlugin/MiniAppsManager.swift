import Foundation

/// Represents a mini-app entry in the registry
public struct MiniAppEntry {
    public let name: String
    public let bundleId: String
    public let isMain: Bool

    public init(name: String, bundleId: String, isMain: Bool) {
        self.name = name
        self.bundleId = bundleId
        self.isMain = isMain
    }

    public func toDict() -> [String: Any] {
        return [
            "name": name,
            "isMain": isMain
        ]
    }
}

/// Result of a mini-app update operation
public struct MiniAppUpdateResult {
    public let success: Bool
    public let newBundleId: String?
    public let error: String?

    public static func success(newBundleId: String) -> MiniAppUpdateResult {
        return MiniAppUpdateResult(success: true, newBundleId: newBundleId, error: nil)
    }

    public static func failure(_ error: String) -> MiniAppUpdateResult {
        return MiniAppUpdateResult(success: false, newBundleId: nil, error: error)
    }

    public static func noUpdate() -> MiniAppUpdateResult {
        return MiniAppUpdateResult(success: true, newBundleId: nil, error: nil)
    }
}

/// Manages mini-apps registry and operations
/// Handles storage, lookup, and lifecycle of mini-apps in a "super-app" architecture
public class MiniAppsManager {
    private let registryKey: String
    private let logger: Logger

    public init(registryKey: String = "CapacitorUpdater.miniApps", logger: Logger) {
        self.registryKey = registryKey
        self.logger = logger
    }

    // MARK: - Registry Operations

    /// Get all mini-apps from registry
    public func getRegistry() -> [String: [String: Any]] {
        guard let data = UserDefaults.standard.string(forKey: registryKey),
              let jsonData = data.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: [String: Any]] else {
            return [:]
        }
        return dict
    }

    /// Save registry to storage
    public func saveRegistry(_ registry: [String: [String: Any]]) {
        if let data = try? JSONSerialization.data(withJSONObject: registry),
           let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: registryKey)
            UserDefaults.standard.synchronize()
        }
    }

    /// Get all protected bundle IDs (bundles that should not be cleaned up)
    public func getProtectedBundleIds() -> Set<String> {
        var ids = Set<String>()
        let registry = getRegistry()
        for (_, entry) in registry {
            if let bundleId = entry["id"] as? String, !bundleId.isEmpty {
                ids.insert(bundleId)
            }
        }
        return ids
    }

    /// Find mini-app info by bundle ID
    public func getMiniAppForBundleId(_ bundleId: String) -> MiniAppEntry? {
        let registry = getRegistry()
        for (name, entry) in registry {
            if let id = entry["id"] as? String, id == bundleId {
                let isMain = entry["isMain"] as? Bool ?? false
                return MiniAppEntry(name: name, bundleId: bundleId, isMain: isMain)
            }
        }
        return nil
    }

    /// Get mini-app entry by name
    public func getMiniApp(name: String) -> MiniAppEntry? {
        let registry = getRegistry()
        guard let entry = registry[name],
              let bundleId = entry["id"] as? String else {
            return nil
        }
        let isMain = entry["isMain"] as? Bool ?? false
        return MiniAppEntry(name: name, bundleId: bundleId, isMain: isMain)
    }

    /// Get bundle ID for mini-app name
    public func getBundleId(forMiniApp name: String) -> String? {
        let registry = getRegistry()
        return registry[name]?["id"] as? String
    }

    /// Get all mini-apps as entries
    public func getAllMiniApps() -> [MiniAppEntry] {
        let registry = getRegistry()
        return registry.compactMap { (name, entry) -> MiniAppEntry? in
            guard let bundleId = entry["id"] as? String else { return nil }
            let isMain = entry["isMain"] as? Bool ?? false
            return MiniAppEntry(name: name, bundleId: bundleId, isMain: isMain)
        }
    }

    // MARK: - Registration

    /// Register a bundle as a mini-app
    /// - Parameters:
    ///   - name: Mini-app name (also used as channel name)
    ///   - bundleId: Bundle ID to register
    ///   - isMain: Whether this is the main app (receives auto-updates)
    /// - Returns: true if registration succeeded
    public func register(name: String, bundleId: String, isMain: Bool) {
        var registry = getRegistry()

        // If isMain is true, clear isMain from all other entries
        if isMain {
            for (existingName, var entry) in registry {
                if entry["isMain"] as? Bool == true {
                    entry["isMain"] = false
                    registry[existingName] = entry
                }
            }
        }

        // Add or update the mini-app entry
        registry[name] = [
            "id": bundleId,
            "isMain": isMain
        ]

        saveRegistry(registry)
        logger.info("Registered mini-app '\(name)' with bundle \(bundleId), isMain: \(isMain)")
    }

    /// Unregister a mini-app from the registry
    /// - Parameter name: Mini-app name to unregister
    /// - Returns: The bundle ID that was unregistered, or nil if not found
    public func unregister(name: String) -> String? {
        var registry = getRegistry()
        guard let entry = registry[name],
              let bundleId = entry["id"] as? String else {
            return nil
        }

        registry.removeValue(forKey: name)
        saveRegistry(registry)
        logger.info("Unregistered mini-app '\(name)', bundle: \(bundleId)")
        return bundleId
    }

    /// Update the bundle ID for an existing mini-app
    /// - Parameters:
    ///   - name: Mini-app name
    ///   - newBundleId: New bundle ID
    /// - Returns: true if update succeeded
    public func updateBundleId(name: String, newBundleId: String) -> Bool {
        var registry = getRegistry()
        guard var entry = registry[name] else {
            return false
        }

        let oldBundleId = entry["id"] as? String ?? ""
        entry["id"] = newBundleId
        registry[name] = entry
        saveRegistry(registry)
        logger.info("Updated mini-app '\(name)' bundle: \(oldBundleId) -> \(newBundleId)")
        return true
    }

    // MARK: - Main App

    /// Get the main app entry (the one that receives auto-updates)
    public func getMainApp() -> MiniAppEntry? {
        let registry = getRegistry()
        for (name, entry) in registry {
            if entry["isMain"] as? Bool == true,
               let bundleId = entry["id"] as? String {
                return MiniAppEntry(name: name, bundleId: bundleId, isMain: true)
            }
        }
        return nil
    }

    /// Check if a mini-app is the main app
    public func isMainApp(name: String) -> Bool {
        let registry = getRegistry()
        return registry[name]?["isMain"] as? Bool ?? false
    }

    // MARK: - App State (Inter-app Communication)

    private func stateKey(for miniApp: String) -> String {
        return "CapacitorUpdater.miniAppState.\(miniApp)"
    }

    /// Write state data for a mini-app
    /// - Parameters:
    ///   - miniApp: The mini-app name
    ///   - state: The state object to save (must be JSON-serializable), or nil to clear
    public func writeState(miniApp: String, state: [String: Any]?) {
        let key = stateKey(for: miniApp)

        if let state = state {
            if let data = try? JSONSerialization.data(withJSONObject: state),
               let str = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(str, forKey: key)
                UserDefaults.standard.synchronize()
                logger.info("Wrote state for mini-app '\(miniApp)'")
            } else {
                logger.error("Failed to serialize state for mini-app '\(miniApp)'")
            }
        } else {
            // Clear state
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.synchronize()
            logger.info("Cleared state for mini-app '\(miniApp)'")
        }
    }

    /// Read state data for a mini-app
    /// - Parameter miniApp: The mini-app name
    /// - Returns: The saved state, or nil if no state exists
    public func readState(miniApp: String) -> [String: Any]? {
        let key = stateKey(for: miniApp)

        guard let data = UserDefaults.standard.string(forKey: key),
              let jsonData = data.data(using: .utf8),
              let state = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }
        return state
    }

    /// Clear state data for a mini-app
    /// - Parameter miniApp: The mini-app name
    public func clearState(miniApp: String) {
        let key = stateKey(for: miniApp)
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.synchronize()
        logger.info("Cleared state for mini-app '\(miniApp)'")
    }
}
