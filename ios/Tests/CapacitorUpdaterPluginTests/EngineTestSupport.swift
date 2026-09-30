import Foundation
@testable import CapacitorUpdaterPlugin

/// Manifest entry as sent to the engine (`file_name`, `file_hash`, `download_url`).
struct ManifestEntry {
    let file_name: String?
    let file_hash: String?
    let download_url: String?

    var dict: [String: Any] {
        var dict: [String: Any] = [:]
        dict["file_name"] = file_name
        dict["file_hash"] = file_hash
        dict["download_url"] = download_url
        return dict
    }
}

/// Engine host that records stats instead of sending them.
class StatsRecordingCapgoUpdater: CapgoUpdater {
    private let statsLock = NSLock()
    private var recordedStats: [String] = []

    var sentStatsActions: [String] {
        statsLock.lock()
        defer { statsLock.unlock() }
        return recordedStats
    }

    override func engineHook(_ name: String, _ payload: [String: Any]) -> [String: Any]? {
        if name == "sendStats" {
            statsLock.lock()
            recordedStats.append(payload["action"] as? String ?? "")
            statsLock.unlock()
            return ["handled": true]
        }
        return super.engineHook(name, payload)
    }
}

/// Engine operations used by the download tests (the plugin reaches them through `pluginMethod`).
extension CapgoUpdater {
    enum EngineError: Error {
        case unavailable
    }

    @discardableResult
    func engineCall(_ operation: String, _ input: [String: Any?] = [:]) throws -> [String: Any] {
        guard let engine = engine() else {
            throw EngineError.unavailable
        }
        return try engine.call(operation, input)
    }

    func setPublicKey(_ publicKey: String) {
        _ = try? engineCall("configure", ["publicKey": publicKey])
    }

    func populateDeltaCache(for id: String) {
        _ = try? engineCall("populateDeltaCache", ["id": id])
    }

    func getMissingBundleFiles(manifest: [ManifestEntry], sessionKey: String) -> [ManifestEntry] {
        let result = (try? engineCall("missingBundleFiles", ["manifest": manifest.map(\.dict), "sessionKey": sessionKey])) ?? [:]
        return (result["missing"] as? [[String: Any]] ?? []).map {
            ManifestEntry(
                file_name: $0["file_name"] as? String,
                file_hash: $0["file_hash"] as? String,
                download_url: $0["download_url"] as? String
            )
        }
    }

    func download(url: URL, version: String, sessionKey: String, checksum: String) throws -> [String: Any] {
        try engineCall("download", [
            "url": url.absoluteString,
            "version": version,
            "sessionKey": sessionKey,
            "checksum": checksum,
            "emitEvents": false
        ])
    }

    func downloadManifest(manifest: [ManifestEntry], version: String, sessionKey: String) throws -> [String: Any] {
        try engineCall("download", [
            "version": version,
            "sessionKey": sessionKey,
            "manifest": manifest.map(\.dict),
            "emitEvents": false
        ])
    }

    func deleteBundle(id: String) {
        _ = try? engineCall("bundleDelete", ["id": id, "removeInfo": true])
    }
}
