/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation

extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
    var exist: Bool {
        return FileManager().fileExists(atPath: self.path)
    }
}
struct SetChannelDec: Decodable {
    let status: String?
    let error: String?
    let message: String?
    let unset: Bool?
}
public class SetChannel: NSObject {
    var status: String = ""
    var error: String = ""
    var message: String = ""
}
extension SetChannel {
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [String: Any]()
        let otherSelf: Mirror = Mirror(reflecting: self)
        for child: Mirror.Child in otherSelf.children {
            if let key: String = child.label {
                dict[key] = child.value
            }
        }
        return dict
    }
}
struct GetChannelDec: Decodable {
    let channel: String?
    let status: String?
    let error: String?
    let message: String?
    let allowSet: Bool?
}
public class GetChannel: NSObject {
    var channel: String = ""
    var status: String = ""
    var error: String = ""
    var message: String = ""
    var allowSet: Bool = true
}
extension GetChannel {
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [String: Any]()
        let otherSelf: Mirror = Mirror(reflecting: self)
        for child: Mirror.Child in otherSelf.children {
            if let key: String = child.label {
                dict[key] = child.value
            }
        }
        return dict
    }
}
struct ChannelInfo: Codable {
    let id: String?
    let name: String?
    let `public`: Bool?
    let allowSelfSet: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name
        case `public`
        case allowSelfSet = "allow_self_set"
    }
}

struct ListChannelsDec: Decodable {
    let channels: [ChannelInfo]?
    let error: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let channelsArray = try? container.decode([ChannelInfo].self) {
            // Backend returns direct array
            self.channels = channelsArray
            self.error = nil
        } else {
            // Handle error response
            let errorContainer = try decoder.container(keyedBy: CodingKeys.self)
            self.channels = nil
            self.error = try? errorContainer.decode(String.self, forKey: .error)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case error
    }
}
public class ListChannels: NSObject {
    var channels: [[String: Any]] = []
    var error: String = ""
}
extension ListChannels {
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [String: Any]()
        let otherSelf: Mirror = Mirror(reflecting: self)
        for child: Mirror.Child in otherSelf.children {
            if let key: String = child.label {
                dict[key] = child.value
            }
        }
        return dict
    }
}
struct InfoObject: Codable {
    let platform: String?
    let deviceId: String?
    let appId: String?
    let customId: String?
    let versionBuild: String?
    let versionCode: String?
    let versionOs: String?
    var versionName: String?
    var oldVersionName: String?
    let pluginVersion: String?
    let isEmulator: Bool?
    let isProd: Bool?
    var action: String?
    var channel: String?
    var defaultChannel: String?
    var keyId: String?
}

extension InfoObject {
    func toParameters() -> [String: Any] {
        var parameters: [String: Any] = [:]
        func set(_ key: String, _ value: Any?) {
            guard let value = value else {
                return
            }
            parameters[key] = value
        }
        set("platform", platform)
        set("device_id", deviceId)
        set("app_id", appId)
        set("custom_id", customId)
        set("version_build", versionBuild)
        set("version_code", versionCode)
        set("version_os", versionOs)
        set("version_name", versionName)
        set("old_version_name", oldVersionName)
        set("plugin_version", pluginVersion)
        set("is_emulator", isEmulator)
        set("is_prod", isProd)
        set("action", action)
        set("channel", channel)
        set("defaultChannel", defaultChannel)
        set("key_id", keyId)
        return parameters
    }
}

struct StatsEvent: Codable {
    let platform: String?
    let deviceId: String?
    let appId: String?
    let customId: String?
    let versionBuild: String?
    let versionCode: String?
    let versionOs: String?
    let versionName: String?
    let oldVersionName: String?
    let pluginVersion: String?
    let isEmulator: Bool?
    let isProd: Bool?
    let action: String?
    let channel: String?
    let defaultChannel: String?
    let keyId: String?
    let metadata: [String: String]?
    let timestamp: Int64

    enum CodingKeys: String, CodingKey {
        case platform
        case deviceId = "device_id"
        case appId = "app_id"
        case customId = "custom_id"
        case versionBuild = "version_build"
        case versionCode = "version_code"
        case versionOs = "version_os"
        case versionName = "version_name"
        case oldVersionName = "old_version_name"
        case pluginVersion = "plugin_version"
        case isEmulator = "is_emulator"
        case isProd = "is_prod"
        case action, channel, defaultChannel, metadata, timestamp
        case keyId = "key_id"
    }
}

public struct ManifestEntry: Codable {
    let fileName: String?
    let fileHash: String?
    let downloadUrl: String?

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case fileHash = "file_hash"
        case downloadUrl = "download_url"
    }
}

extension ManifestEntry {
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [:]
        if let fileName {
            dict["file_name"] = fileName
        }
        if let fileHash {
            dict["file_hash"] = fileHash
        }
        if let downloadUrl {
            dict["download_url"] = downloadUrl
        }
        return dict
    }
}

struct AppVersionDec: Decodable {
    let version: String?
    let checksum: String?
    let url: String?
    let message: String?
    let error: String?
    let kind: String?
    let sessionKey: String?
    let major: Bool?
    let breaking: Bool?
    let data: [String: String]?
    let manifest: [ManifestEntry]?
    let link: String?
    let comment: String?
    // The HTTP status code is captured separately in CapgoUpdater; this struct only mirrors JSON.

    enum CodingKeys: String, CodingKey {
        case version, checksum, url, message, error, kind, major, breaking, data, manifest, link, comment
        case sessionKey = "session_key"
    }
}

public class AppVersion: NSObject {
    var version: String = ""
    var checksum: String = ""
    var url: String = ""
    var message: String?
    var error: String?
    var kind: String?
    var sessionKey: String?
    var major: Bool?
    var breaking: Bool?
    var data: [String: String]?
    var manifest: [ManifestEntry]?
    var missing: [String: Any]?
    var downloadSize: [String: Any]?
    var link: String?
    var comment: String?
    var statusCode: Int = 0
}

extension AppVersion {
    func toDict() -> [String: Any] {
        var dict: [String: Any] = [String: Any]()
        let otherSelf: Mirror = Mirror(reflecting: self)
        for child: Mirror.Child in otherSelf.children {
            if let key: String = child.label {
                if key == "manifest", let manifestEntries = child.value as? [ManifestEntry] {
                    dict[key] = manifestEntries.map { $0.toDict() }
                } else {
                    dict[key] = child.value
                }
            }
        }
        return dict
    }
}

extension OperatingSystemVersion {
    func getFullVersion(separator: String = ".") -> String {
        return "\(majorVersion)\(separator)\(minorVersion)\(separator)\(patchVersion)"
    }
}
extension Bundle {
    var versionName: String? {
        return infoDictionary?["CFBundleShortVersionString"] as? String
    }
    var versionCode: String? {
        return infoDictionary?["CFBundleVersion"] as? String
    }
}

extension ISO8601DateFormatter {
    convenience init(_ formatOptions: Options) {
        self.init()
        self.formatOptions = formatOptions
    }
}
extension Formatter {
    static let iso8601withFractionalSeconds: ISO8601DateFormatter = ISO8601DateFormatter(
        [.withInternetDateTime, .withFractionalSeconds])
}
extension Date {
    var iso8601withFractionalSeconds: String { return Formatter.iso8601withFractionalSeconds.string(from: self) }
}
extension String {

    var fileURL: URL {
        return URL(fileURLWithPath: self)
    }

    var lastPathComponent: String {
        get {
            return fileURL.lastPathComponent
        }
    }
    var iso8601withFractionalSeconds: Date? {
        return Formatter.iso8601withFractionalSeconds.date(from: self)
    }
    func trim(using characterSet: CharacterSet = .whitespacesAndNewlines) -> String {
        return trimmingCharacters(in: characterSet)
    }
}

enum CustomError: Error {
    // Throw when an unzip fail
    case cannotUnzip
    case cannotWrite
    case cannotDecode
    case cannotUnflat
    case cannotCreateDirectory
    case cannotDeleteDirectory
    case cannotDecryptSessionKey
    case invalidBase64
    case insufficientDiskSpace

    // Throw in all other cases
    case unexpected(code: Int)
}

extension CustomError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cannotUnzip:
            return NSLocalizedString(
                "The file cannot be unzip",
                comment: "Invalid zip"
            )
        case .cannotCreateDirectory:
            return NSLocalizedString(
                "The folder cannot be created",
                comment: "Invalid folder"
            )
        case .cannotDeleteDirectory:
            return NSLocalizedString(
                "The folder cannot be deleted",
                comment: "Invalid folder"
            )
        case .cannotUnflat:
            return NSLocalizedString(
                "The file cannot be unflat",
                comment: "Invalid folder"
            )
        case .unexpected:
            return NSLocalizedString(
                "An unexpected error occurred.",
                comment: "Unexpected Error"
            )
        case .cannotDecode:
            return NSLocalizedString(
                "Decoding the zip failed with this key",
                comment: "Invalid public key"
            )
        case .cannotWrite:
            return NSLocalizedString(
                "Cannot write to the destination",
                comment: "Invalid destination"
            )
        case .cannotDecryptSessionKey:
            return NSLocalizedString(
                "Decrypting the session key failed",
                comment: "Invalid session key"
            )
        case .invalidBase64:
            return NSLocalizedString(
                "Decrypting the base64 failed",
                comment: "Invalid checksum key"
            )
        case .insufficientDiskSpace:
            return NSLocalizedString(
                "Insufficient disk space for download",
                comment: "Not enough storage"
            )
        }
    }
}

/// Thread-safe atomic counter for concurrent operations
final class AtomicCounter {
    private var value: Int = 0
    private let lock = NSLock()

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Thread-safe atomic boolean for concurrent operations
final class AtomicBool {
    private var _value: Bool
    private let lock = NSLock()

    init(initialValue: Bool = false) {
        _value = initialValue
    }

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }
}
