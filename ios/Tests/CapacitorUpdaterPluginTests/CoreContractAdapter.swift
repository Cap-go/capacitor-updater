import Foundation
@testable import CapacitorUpdaterPlugin

/// Maps a shared core contract operation (`group` + JSON `input`) onto the
/// plugin's Swift API (backed by the Rust core) and returns the JSON output object.
///
/// Success returns a dictionary with exactly the keys of the fixture `expect`.
/// Contract errors (`expect: {"error": ...}`) must surface as a thrown error;
/// the error type is not compared here (the Rust contract runner checks codes).
/// Malformed fixture input throws `CoreContractAdapter.InputError`, which the
/// runner always reports as a failure.
enum CoreContractAdapter {
    struct InputError: Error, CustomStringConvertible {
        let description: String
    }

    typealias Operation = (ContractInput) throws -> [String: Any]

    /// Groups the iOS plugin has no Swift wrapper for (Android download-flow
    /// helpers). They still run on iOS, straight through the core binding.
    static let coreOnlyGroups: Set<String> = [
        "launchDownloadReady",
        "contentRange",
        "zipResumePlan",
        "builtinAssetPath"
    ]

    static func run(group: String, input: [String: Any]) throws -> [String: Any] {
        if coreOnlyGroups.contains(group) {
            return try CapgoCore.call(group, input.mapValues { $0 as Any? })
        }
        guard let operation = operations[group] else {
            throw InputError(description: "No iOS adapter for group \(group)")
        }
        return try operation(ContractInput(values: input))
    }

    private static let operations: [String: Operation] = policyOperations
        .merging(httpOperations) { $1 }
        .merging(securityOperations) { $1 }
        .merging(cryptoOperations) { $1 }

    // MARK: - policy.json

    private static let policyOperations: [String: Operation] = [
        "legacyDirectUpdateAutoMode": { input in
            ["mode": CapacitorUpdaterPlugin.autoUpdateModeForLegacyDirectUpdateMode(try input.string("directUpdateMode"))]
        },
        "isDirectUpdateMode": { input in
            ["direct": CapacitorUpdaterPlugin.isDirectUpdateMode(try input.string("directUpdateMode"))]
        },
        "shakeMenuGesture": { input in
            let value = try input.optionalString("value")
            return [
                "gesture": CapacitorUpdaterPlugin.normalizedShakeMenuGesture(value),
                "supported": CapacitorUpdaterPlugin.isSupportedShakeMenuGesture(value)
            ]
        },
        "webViewErrorStatsAction": { input in
            ["action": WebViewStatsReporter.statsAction(for: try input.string("type"))]
        },
        "foreignBundleReset": { input in
            ["reset": CapgoUpdater.shouldResetForForeignBundle(
                bundlePath: try input.optionalString("bundlePath"),
                isBuiltin: try input.bool("isBuiltin"),
                hasStoredBundleInfo: try input.bool("hasStoredBundleInfo")
            )]
        },
        "clearPersistedDefaultChannel": { input in
            let plugin = CapacitorUpdaterPlugin()
            plugin.persistDefaultChannelOnReinstall = try input.bool("persistDefaultChannelOnReinstall")
            return ["clear": plugin.shouldClearPersistedDefaultChannel(
                nativeBuildVersionChanged: try input.bool("nativeBuildVersionChanged"),
                resetWhenUpdate: try input.bool("resetWhenUpdate"),
                restoredReinstall: try input.bool("restoredReinstall")
            )]
        },
        "manifestConcurrency": { input in
            ["maxConcurrentFiles": CapgoUpdater.clampedManifestConcurrency(processorCount: try input.int("processorCount"))]
        },
        "bundleStatus": { input in
            let status = BundleStatus(storedValue: try input.string("value"))
            return ["status": status.map { $0.storedValue as Any } ?? NSNull()]
        }
    ]

    private static let httpOperations: [String: Operation] = [
        "userAgent": { input in
            // The iOS builder hard codes the platform; other platforms go straight to the core.
            guard try input.string("platform") == "ios" else {
                return try CapgoCore.call("userAgent", input.values.mapValues { $0 as Any? })
            }
            return ["userAgent": CapgoUpdater.buildUserAgent(
                appId: try input.string("appId"),
                pluginVersion: try input.string("pluginVersion"),
                versionOs: try input.string("versionOs")
            )]
        },
        "retryableHttpStatus": { input in
            ["retryable": CapgoUpdater.isTransientStatsFailure(try input.int("status"))]
        },
        "appendHttpBody": { input in
            ["append": CapgoUpdater.shouldAppendHttpBody(
                statusCode: try input.int("statusCode"),
                existingBytes: Int64(try input.int("existingBytes"))
            )]
        },
        "rateLimitDeadline": { input in
            ["blockedUntilMs": CapgoUpdater.resolveRateLimitBlockedUntilMs(
                retryAfterHeader: try input.optionalString("retryAfter"),
                data: try input.optionalString("body").map { Data($0.utf8) },
                nowMs: try input.double("nowMs")
            )]
        },
        "remoteError": { input in
            let parsed = CapgoUpdater.parseRemoteError(data: try input.optionalString("body").map { Data($0.utf8) })
            return ["error": parsed.error, "message": parsed.message]
        }
    ]

    // MARK: - security.json

    private static let securityOperations: [String: Operation] = [
        "pathTraversalSegment": { input in
            ["traversal": CapgoUpdater.containsPathTraversalSegment(try input.string("path"))]
        },
        "resolvePathInside": { input in
            let resolved = try CapgoUpdater.resolvePathInsideDirectory(
                baseDirectory: URL(fileURLWithPath: try input.string("base")),
                relativePath: try input.string("path")
            )
            return ["path": resolved.path]
        },
        "manifestTargetPath": { input in
            let resolved = try CapgoUpdater.resolveManifestTargetPath(
                baseDirectory: URL(fileURLWithPath: try input.string("base")),
                fileName: try input.string("fileName")
            )
            return ["path": resolved.path]
        },
        "safeCacheHash": { input in
            // A missing manifest hash is never a safe cache key; the Swift helper only takes a String.
            ["safe": try input.optionalString("hash").map { CapgoUpdater.isSafeCacheHash($0) } ?? false]
        },
        "reusableCacheFile": { input in
            ["reusable": try withTemporaryDirectory { directory in
                let file = directory.appendingPathComponent("cache-entry")
                if let size = try input.optionalInt("size") {
                    try Data(count: size).write(to: file)
                }
                return CapgoUpdater.isReusableCacheFile(file, expectedHash: try input.string("hash"))
            }]
        },
        "manifestPartialName": { input in
            let url = CapgoUpdater.manifestPartialURL(
                cacheFolder: FileManager.default.temporaryDirectory,
                hash: try input.string("hash"),
                fileName: try input.string("fileName")
            )
            return ["name": url.lastPathComponent]
        },
        "shortPathKey": { input in
            ["key": CryptoCipher.shortPathKey(try input.string("value"))]
        }
    ]

    // MARK: - crypto.json

    private static let cryptoOperations: [String: Operation] = [
        "sessionKeyValid": { input in
            ["valid": CryptoCipher.isValidSessionKey(try input.string("sessionKey"))]
        },
        "keyId": { input in
            ["keyId": CryptoCipher.calcKeyId(publicKey: try input.string("publicKey"))]
        },
        "publicKeyValid": { input in
            ["valid": RSAPublicKey.load(rsaPublicKey: try input.string("publicKey")) != nil]
        },
        "checksumAlgorithm": { input in
            ["algorithm": CryptoCipher.detectChecksumAlgorithm(try input.string("checksum"))]
        },
        "checksumFile": { input in
            let chunk = try hexData(try input.string("contentHex"))
            let content = Data((0..<max(0, try input.int("repeat"))).flatMap { _ in chunk })
            return ["checksum": try withTemporaryDirectory { directory in
                let file = directory.appendingPathComponent("checksum-input")
                try content.write(to: file)
                return CryptoCipher.calcChecksum(filePath: file)
            }]
        },
        "decryptChecksum": { input in
            ["checksum": try CryptoCipher.decryptChecksum(
                checksum: try input.string("checksum"),
                publicKey: try input.string("publicKey")
            )]
        },
        "decryptFile": { input in
            let ciphertext = try hexData(try input.string("ciphertextHex"))
            return ["plaintextHex": try withTemporaryDirectory { directory in
                let file = directory.appendingPathComponent("bundle.zip")
                try ciphertext.write(to: file)
                try CryptoCipher.decryptFile(
                    filePath: file,
                    publicKey: try input.string("publicKey"),
                    sessionKey: try input.string("sessionKey"),
                    version: "core-contract"
                )
                return hexString(try Data(contentsOf: file))
            }]
        }
    ]

    // MARK: - Helpers

    private static func hexData(_ hex: String) throws -> Data {
        let bytes = Array(hex.utf8)
        guard bytes.count.isMultiple(of: 2) else {
            throw InputError(description: "odd-length hex")
        }
        var data = Data(capacity: bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let pair = String(bytes: bytes[index...index + 1], encoding: .ascii),
                  let byte = UInt8(pair, radix: 16) else {
                throw InputError(description: "invalid hex")
            }
            data.append(byte)
        }
        return data
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        return try body(directory)
    }
}

/// Typed access to a fixture `input` object. JSON `null` maps to Swift `nil`.
struct ContractInput {
    let values: [String: Any]

    func string(_ key: String) throws -> String {
        guard let value = values[key] as? String else {
            throw CoreContractAdapter.InputError(description: "\(key) must be a string")
        }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = values[key], !(value is NSNull) else {
            return nil
        }
        return try string(key)
    }

    func bool(_ key: String) throws -> Bool {
        guard let value = values[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw CoreContractAdapter.InputError(description: "\(key) must be a boolean")
        }
        return value.boolValue
    }

    func int(_ key: String) throws -> Int {
        Int(try number(key).int64Value)
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let value = values[key], !(value is NSNull) else {
            return nil
        }
        return try int(key)
    }

    func double(_ key: String) throws -> Double {
        try number(key).doubleValue
    }

    private func number(_ key: String) throws -> NSNumber {
        guard let value = values[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else {
            throw CoreContractAdapter.InputError(description: "\(key) must be a number")
        }
        return value
    }
}
